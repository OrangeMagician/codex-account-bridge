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

type remoteDesktopConnection struct {
	PID  int    `json:"pid"`
	Home string `json:"home"`
}

type remoteVerification struct {
	Account                   string                    `json:"account"`
	Home                      string                    `json:"home"`
	FreshConnectionVerified   bool                      `json:"fresh_connection_verified"`
	OtherAccountProcesses     int                       `json:"other_account_processes"`
	UnknownProcesses          int                       `json:"unknown_processes"`
	ProcessesChecked          bool                      `json:"processes_checked"`
	DesktopConnections        []remoteDesktopConnection `json:"desktop_connections"`
	DesktopConnectionsChecked bool                      `json:"desktop_connections_checked"`
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
	report := inspectRemoteConnections(account)
	report.FreshConnectionVerified = true
	if *jsonOutput {
		return printJSON(report)
	}
	fmt.Printf("verified next remote connection: %s\nexisting connections on other homes: %d\n", report.Account, report.OtherAccountProcesses)
	return 0, nil
}

// Existing desktop listeners are inspected independently of the disposable
// verification server. Agent/CLI stdio servers are not desktop connections.
func inspectRemoteConnections(account config.Account) remoteVerification {
	processes, err := codexprocess.List()
	if err != nil {
		return remoteVerification{Account: account.Name, Home: account.Home, DesktopConnections: []remoteDesktopConnection{}}
	}
	return remoteConnectionsFromProcesses(account, processes, codexprocess.DescribeRoute)
}

func remoteConnectionsFromProcesses(account config.Account, processes []codexprocess.Process, describe func(codexprocess.Process, string) codexprocess.RouteDetails) remoteVerification {
	report := remoteVerification{Account: account.Name, Home: account.Home, DesktopConnections: []remoteDesktopConnection{}}
	report.ProcessesChecked = true
	home, _ := os.UserHomeDir()
	for _, process := range processes {
		route := describe(process, filepath.Join(home, ".codex"))
		if route.Role == "bridge" {
			continue
		}
		if !route.Verified {
			report.UnknownProcesses++
			continue
		}
		if filepath.Clean(route.Home) != filepath.Clean(account.Home) {
			report.OtherAccountProcesses++
		}
		if route.Desktop {
			report.DesktopConnections = append(report.DesktopConnections, remoteDesktopConnection{PID: process.PID, Home: route.Home})
		}
	}
	report.DesktopConnectionsChecked = report.UnknownProcesses == 0
	return report
}

func remoteConnectionsCommand(cfg config.Config, args []string) (int, error) {
	flags := newFlags("remote connections")
	name := flags.String("account", "", "selected remote account")
	jsonOutput := flags.Bool("json", false, "print existing desktop connection state")
	if err := flags.Parse(args); err != nil || flags.NArg() != 0 || *name == "" {
		return 2, errors.New("usage: cab remote connections --account NAME [--json]")
	}
	account, ok := cfg.Find(*name)
	if !ok || (cfg.RemoteAccount != "" && cfg.RemoteAccount != account.Name) {
		return 1, errors.New("remote account selection changed; refresh before verifying")
	}
	report := inspectRemoteConnections(account)
	if *jsonOutput {
		return printJSON(report)
	}
	fmt.Printf("existing desktop connections: %d; inspection complete: %t\n", len(report.DesktopConnections), report.DesktopConnectionsChecked)
	return 0, nil
}
