package app

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"time"

	"github.com/OrangeMagician/codex-account-bridge/internal/codex"
	"github.com/OrangeMagician/codex-account-bridge/internal/codexprocess"
	"github.com/OrangeMagician/codex-account-bridge/internal/config"
)

type diagnosticCheck struct {
	ID     string `json:"id"`
	OK     bool   `json:"ok"`
	Detail string `json:"detail"`
}

type diagnosticReport struct {
	CABVersion     string                 `json:"cab_version"`
	CodexPath      string                 `json:"codex_path"`
	CodexVersion   string                 `json:"codex_version"`
	EntryPoint     string                 `json:"entry_point"`
	DefaultAccount string                 `json:"default_account"`
	RemoteAccount  string                 `json:"remote_account"`
	Capabilities   []string               `json:"capabilities"`
	Checks         []diagnosticCheck      `json:"checks"`
	Processes      []codexprocess.Process `json:"processes"`
	Routes         []processRoute         `json:"routes"`
}

type processRoute struct {
	PID                   int    `json:"pid"`
	Account               string `json:"account,omitempty"`
	Home                  string `json:"home,omitempty"`
	Role                  string `json:"role"`
	Verified              bool   `json:"verified"`
	MatchesNextConnection bool   `json:"matches_next_connection"`
}

var supportedCapabilities = []string{"remote-verify-v1", "doctor-json-v1", "backups-v1", "project-directory-v1", "usage", "tokens", "incremental-tokens-v1", "sessions", "agent", "update", "models-v1", "launch-presets-v1", "tasks-v1", "process-routing-v1", "worktrees-v1"}

func diagnostics(paths config.Paths, cfg config.Config, version string, checks []diagnosticCheck) diagnosticReport {
	report := diagnosticReport{CABVersion: version, DefaultAccount: cfg.DefaultAccount, RemoteAccount: cfg.RemoteAccount, Capabilities: supportedCapabilities, Checks: checks, Processes: []codexprocess.Process{}}
	report.EntryPoint, _ = exec.LookPath("codex")
	binary, err := codex.FindReal("codex")
	if err == nil {
		report.CodexPath = binary
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		data, err := exec.CommandContext(ctx, binary, "--version").Output()
		if err == nil {
			report.CodexVersion = string(data)
		}
		report.Checks = append(report.Checks, diagnosticCheck{"codex-version", err == nil, "Official Codex version query"})
	}
	python := ""
	for _, candidate := range []string{"/usr/bin/python3", "/bin/python3", "/opt/homebrew/bin/python3"} {
		if info, err := os.Stat(candidate); err == nil && info.Mode().IsRegular() && info.Mode().Perm()&0111 != 0 {
			python = candidate
			break
		}
	}
	if python != "" {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		out, err := exec.CommandContext(ctx, python, "-I", "-c", "import sqlite3,sys; print(sys.version.split()[0] + ' / SQLite ' + sqlite3.sqlite_version)").Output()
		report.Checks = append(report.Checks, diagnosticCheck{"python-sqlite", err == nil, python + " " + string(out)})
	} else {
		report.Checks = append(report.Checks, diagnosticCheck{"python-sqlite", false, "Python 3 with sqlite3 is required"})
	}
	if processes, err := codexprocess.List(); err == nil {
		report.Processes = processes
		report.Routes = []processRoute{}
		userHome, _ := os.UserHomeDir()
		for _, process := range processes {
			detail := codexprocess.DescribeRoute(process, filepath.Join(userHome, ".codex"))
			route := processRoute{PID: process.PID, Home: detail.Home, Role: detail.Role, Verified: detail.Verified}
			for _, account := range cfg.Accounts {
				if detail.Verified && filepath.Clean(account.Home) == detail.Home {
					route.Account = account.Name
					route.MatchesNextConnection = account.Name == cfg.RemoteAccount
					break
				}
			}
			report.Routes = append(report.Routes, route)
		}
	} else {
		report.Checks = append(report.Checks, diagnosticCheck{"processes", false, "Cannot inspect running Codex processes"})
	}
	if report.EntryPoint != "" {
		resolved, _ := filepath.EvalSymlinks(report.EntryPoint)
		cab, _ := os.Executable()
		cab, _ = filepath.EvalSymlinks(cab)
		report.Checks = append(report.Checks, diagnosticCheck{"shim", resolved == cab, "PATH entry: " + report.EntryPoint + "; resolved: " + resolved})
	}
	return report
}
