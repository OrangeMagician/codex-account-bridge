package app

import (
	"errors"
	"fmt"
	"github.com/OrangeMagician/codex-account-bridge/internal/codexprocess"
	"github.com/OrangeMagician/codex-account-bridge/internal/config"
	"github.com/OrangeMagician/codex-account-bridge/internal/maintenance"
	"github.com/OrangeMagician/codex-account-bridge/internal/session"
	"os/exec"
)

func backupsCommand(paths config.Paths, cfg config.Config, args []string) (int, error) {
	if len(args) == 0 {
		return 2, errors.New("backups requires list, preview, restore or delete")
	}
	flags := newFlags("backups")
	id := flags.String("id", "", "backup ID from list")
	action := flags.String("action", "restore", "preview action")
	jsonOutput := flags.Bool("json", false, "JSON output")
	confirm := flags.Bool("confirm", false, "confirm the exact backup operation")
	stopped := flags.Bool("confirm-codex-stopped", false, "confirm all Codex processes are stopped")
	if err := flags.Parse(args[1:]); err != nil {
		return 2, err
	}
	if flags.NArg() != 0 {
		return 2, errors.New("unexpected backup arguments")
	}
	if args[0] == "list" {
		items, err := maintenance.List(paths, cfg)
		if err != nil {
			return 1, err
		}
		if *jsonOutput {
			return printJSON(map[string]any{"backups": items})
		}
		for _, item := range items {
			fmt.Printf("%s\t%s\t%d\t%s\n", item.ID, item.Account, item.Bytes, item.Path)
		}
		return 0, nil
	}
	if args[0] != "preview" && args[0] != "restore" && args[0] != "delete" {
		return 2, errors.New("unknown backup operation")
	}
	operation := args[0]
	if operation == "preview" {
		operation = *action
	}
	if args[0] != "preview" && (!*confirm || operation == "restore" && !*stopped) {
		return 2, errors.New("backup mutation requires --confirm; restore also requires --confirm-codex-stopped")
	}
	perform := func() (int, error) {
		plan, err := maintenance.Plan(paths, cfg, *id, operation)
		if err != nil {
			return 1, err
		}
		if args[0] == "preview" {
			return printJSON(plan)
		}
		if pending, err := session.RecoveryStatus(paths, cfg); err != nil || pending {
			return 1, errors.New("resolve pending session recovery before managing backups")
		}
		if operation == "restore" {
			processes, err := codexprocess.List()
			if err != nil {
				return 1, err
			}
			if len(processes) > 0 {
				return 1, errors.New("quit all Codex processes before restoring")
			}
			for _, name := range []string{"Codex", "ChatGPT"} {
				pgrep := "/usr/bin/pgrep"
				if err := exec.Command(pgrep, "-x", name).Run(); err == nil {
					return 1, errors.New("quit the Codex desktop app before restoring")
				} else {
					var exitErr *exec.ExitError
					if !errors.As(err, &exitErr) || exitErr.ExitCode() != 1 {
						return 1, errors.New("cannot verify desktop process state")
					}
				}
			}
		}
		rollback, err := maintenance.Apply(plan)
		if err != nil {
			return 1, err
		}
		if *jsonOutput {
			return printJSON(map[string]any{"completed": true, "rollback_backup": rollback})
		}
		fmt.Println("backup operation completed")
		return 0, nil
	}
	if args[0] == "preview" {
		return perform()
	}
	unlock, err := session.AcquireMaintenanceLease(paths)
	if err != nil {
		return 1, err
	}
	defer unlock()
	return perform()
}
