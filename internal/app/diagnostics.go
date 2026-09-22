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
}

var supportedCapabilities = []string{"doctor-json-v1", "backups-v1", "project-directory-v1", "usage", "tokens", "incremental-tokens-v1", "sessions", "agent", "update"}

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
