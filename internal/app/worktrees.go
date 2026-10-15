package app

import (
	"errors"
	"fmt"

	"github.com/OrangeMagician/codex-account-bridge/internal/codexprocess"
	"github.com/OrangeMagician/codex-account-bridge/internal/config"
	"github.com/OrangeMagician/codex-account-bridge/internal/session"
	"github.com/OrangeMagician/codex-account-bridge/internal/worktree"
)

func worktreesCommand(paths config.Paths, cfg config.Config, args []string) (int, error) {
	if len(args) == 0 {
		return 2, errors.New("worktrees requires list, create or remove")
	}
	f := newFlags("worktrees")
	name := f.String("account", "", "explicit account")
	directory := f.String("directory", "", "repository")
	ref := f.String("ref", "HEAD", "starting ref")
	id := f.String("id", "", "registered ID")
	confirm := f.Bool("confirm", false, "confirm removal")
	stopped := f.Bool("confirm-codex-stopped", false, "confirm Codex stopped")
	jsonOutput := f.Bool("json", false, "JSON")
	if err := f.Parse(args[1:]); err != nil || f.NArg() != 0 || *name == "" {
		return 2, errors.New("worktrees requires an explicit --account NAME")
	}
	if _, err := selectedAccount(cfg, *name); err != nil {
		return 2, err
	}
	switch args[0] {
	case "list":
		entries, err := worktree.List(paths.DataDir, *name)
		if err != nil {
			return 1, err
		}
		if *jsonOutput {
			return printJSON(map[string]any{"worktrees": entries})
		}
		for _, e := range entries {
			fmt.Printf("%s\t%s\n", e.ID, e.Path)
		}
		return 0, nil
	case "create":
		if *directory == "" {
			return 2, errors.New("repository directory is required")
		}
		var entry worktree.Entry
		_, err := config.UpdateSimple(paths, func(latest *config.Config) error {
			if _, err := selectedAccount(*latest, *name); err != nil {
				return err
			}
			var err error
			entry, err = worktree.Create(paths.DataDir, *name, *directory, *ref)
			return err
		})
		if err != nil {
			return 1, err
		}
		if *jsonOutput {
			return printJSON(entry)
		}
		fmt.Println(entry.Path)
		return 0, nil
	case "remove":
		if !*confirm || !*stopped {
			return 2, errors.New("removal requires --confirm --confirm-codex-stopped")
		}
		unlock, err := exclusiveCodexStopped(paths)
		if err != nil {
			return 1, err
		}
		defer unlock()
		_, err = config.UpdateSimple(paths, func(latest *config.Config) error {
			if _, err := selectedAccount(*latest, *name); err != nil {
				return err
			}
			return worktree.Remove(paths.DataDir, *name, *id)
		})
		if err != nil {
			return 1, err
		}
		if *jsonOutput {
			return printJSON(map[string]any{"completed": true})
		}
		fmt.Println("worktree removed")
		return 0, nil
	default:
		return 2, errors.New("worktrees requires list, create or remove")
	}
}

func exclusiveCodexStopped(paths config.Paths) (func(), error) {
	// Use the same exclusive lease as session maintenance.
	unlock, err := session.AcquireMaintenanceLease(paths)
	if err != nil {
		return nil, err
	}
	processes, err := codexprocess.List()
	if err != nil || len(processes) != 0 {
		unlock()
		return nil, errors.New("stop all Codex processes before removing a worktree")
	}
	return unlock, nil
}
