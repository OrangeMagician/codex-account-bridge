package app

import (
	"github.com/OrangeMagician/codex-account-bridge/internal/codexprocess"
	"github.com/OrangeMagician/codex-account-bridge/internal/config"
	"testing"
)

func TestExistingDesktopVerificationIgnoresWrapperAndStdioAgentHomes(t *testing.T) {
	routes := []codexprocess.RouteDetails{
		{Role: "bridge"},
		{Home: "/accounts/old", Role: "app-server", Verified: true},
		{Home: "/accounts/work", Role: "app-server", Verified: true, Desktop: true},
		{Home: "/accounts/old", Role: "app-server", Verified: true, Desktop: true},
	}
	processes := []codexprocess.Process{{PID: 1}, {PID: 2}, {PID: 3}, {PID: 4}}
	account := config.Account{Name: "work", Home: "/accounts/work"}
	report := remoteConnectionsFromProcesses(account, processes, func(p codexprocess.Process, _ string) codexprocess.RouteDetails { return routes[p.PID-1] })
	if !report.DesktopConnectionsChecked || report.FreshConnectionVerified || report.UnknownProcesses != 0 || len(report.DesktopConnections) != 2 || report.DesktopConnections[0].PID != 3 || report.OtherAccountProcesses != 2 {
		t.Fatalf("unexpected report: %+v", report)
	}
	routes[0] = codexprocess.RouteDetails{Role: "unknown"}
	report = remoteConnectionsFromProcesses(account, processes, func(p codexprocess.Process, _ string) codexprocess.RouteDetails { return routes[p.PID-1] })
	if report.DesktopConnectionsChecked || report.UnknownProcesses != 1 {
		t.Fatalf("unknown process incorrectly confirmed: %+v", report)
	}
}

func TestExistingConnectionsCannotInspectStaleAccountSelection(t *testing.T) {
	cfg := config.Config{RemoteAccount: "other", Accounts: []config.Account{{Name: "work", Home: "/accounts/work"}}}
	for _, args := range [][]string{{"--account", "work", "--json"}, {"--json"}} {
		code, err := remoteConnectionsCommand(cfg, args)
		if code == 0 || err == nil {
			t.Fatalf("invalid request accepted: %v", args)
		}
	}
}

func TestRemoteVerificationCannotVerifyDifferentSavedSelection(t *testing.T) {
	cfg := config.Config{RemoteAccount: "old", Accounts: []config.Account{{Name: "selected", Home: "/accounts/selected"}}}
	code, err := remoteVerifyCommand(cfg, []string{"--account", "selected", "--json"})
	if code == 0 || err == nil {
		t.Fatalf("wrong saved selection verified: %d %v", code, err)
	}
}
