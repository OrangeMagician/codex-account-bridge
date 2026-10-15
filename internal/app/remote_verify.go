package app

import (
	"errors"
	"fmt"
	"github.com/OrangeMagician/codex-account-bridge/internal/codex"
	"github.com/OrangeMagician/codex-account-bridge/internal/codexprocess"
	"github.com/OrangeMagician/codex-account-bridge/internal/config"
	"os"
	"path/filepath"
)

type remoteVerification struct {
	Account                 string `json:"account"`
	Home                    string `json:"home"`
	FreshConnectionVerified bool   `json:"fresh_connection_verified"`
	OtherAccountProcesses   int    `json:"other_account_processes"`
	UnknownProcesses        int    `json:"unknown_processes"`
	ProcessesChecked        bool   `json:"processes_checked"`
}

func remoteVerifyCommand(cfg config.Config, args []string) (int, error) {
	flags := newFlags("remote verify")
	name := flags.String("account", "", "account expected for the next SSH connection")
	jsonOutput := flags.Bool("json", false, "print verified new-connection state")
	if err := flags.Parse(args); err != nil || flags.NArg() != 0 || *name == "" {
		return 2, errors.New("usage: cab remote verify --account NAME [--json]")
	}
	account, ok := cfg.Find(*name)
	if !ok || cfg.RemoteAccount != account.Name {
		return 1, errors.New("remote account selection changed; refresh before verifying")
	}
	if err := codex.VerifyRemoteEntry(account.Home); err != nil {
		return 1, err
	}
	report := remoteVerification{Account: account.Name, Home: account.Home, FreshConnectionVerified: true}
	if processes, err := codexprocess.List(); err == nil {
		report.ProcessesChecked = true
		home, _ := os.UserHomeDir()
		for _, process := range processes {
			// CAB wrapper environments are inherited from their parent and
			// cannot identify the official child's actual account.
			if filepath.Base(process.Executable) != "codex" {
				continue
			}
			route := codexprocess.DescribeRoute(process, filepath.Join(home, ".codex"))
			if !route.Verified {
				report.UnknownProcesses++
				continue
			}
			if filepath.Clean(route.Home) != filepath.Clean(account.Home) {
				report.OtherAccountProcesses++
			}
		}
	}
	if *jsonOutput {
		return printJSON(report)
	}
	fmt.Printf("verified next remote connection: %s\nexisting connections on other homes: %d\n", report.Account, report.OtherAccountProcesses)
	return 0, nil
}
