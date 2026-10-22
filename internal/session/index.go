package session

import (
	"bytes"
	"context"
	_ "embed"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"time"

	"github.com/OrangeMagician/codex-account-bridge/internal/config"
)

// The system Python sqlite3 module provides online, WAL-aware SQLite backups
// and transactions without adding a Go module or copying account databases.
//
//go:embed index_sync.py
var indexSyncScript string

type IndexRepairReport struct {
	Updated int      `json:"updated"`
	Backups []string `json:"backups"`
}

// RepairIndexes only operates after the user has opted into shared history.
// Callers hold a session run lease so a concurrent layout change cannot move
// the history directories while the index is being repaired.
func RepairIndexes(paths config.Paths, cfg config.Config) (IndexRepairReport, error) {
	return RepairIndexesFrom(paths, cfg, "")
}

// RepairIndexesFrom uses the explicitly selected outgoing account for pin and
// section edits; timestamps alone cannot order these user-managed fields.
func RepairIndexesFrom(paths config.Paths, cfg config.Config, sourceHome string) (IndexRepairReport, error) {
	var report IndexRepairReport
	if cfg.SharedSessionsDir == "" {
		return report, nil
	}
	homes := make([]string, 0, len(cfg.Accounts))
	hasIndex := false
	for _, account := range cfg.Accounts {
		homes = append(homes, account.Home)
		if _, err := os.Lstat(filepath.Join(account.Home, "state_5.sqlite")); err == nil {
			hasIndex = true
		} else if !os.IsNotExist(err) {
			return report, err
		}
	}
	if !hasIndex {
		return report, nil // Codex creates its own schema and initial index.
	}
	python := ""
	for _, candidate := range []string{"/usr/bin/python3", "/bin/python3"} {
		if info, err := os.Stat(candidate); err == nil && info.Mode().IsRegular() && info.Mode().Perm()&0o111 != 0 {
			python = candidate
			break
		}
	}
	if python == "" {
		return report, fmt.Errorf("shared session index repair requires system Python 3 with sqlite3; account was not switched")
	}
	input, err := json.Marshal(map[string]any{"homes": homes, "shared": cfg.SharedSessionsDir, "data": paths.DataDir, "source_home": sourceHome})
	if err != nil {
		return report, err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	cmd := exec.CommandContext(ctx, python, "-I", "-c", indexSyncScript)
	cmd.Stdin = bytes.NewReader(input)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	output, err := cmd.Output()
	if err != nil {
		return report, fmt.Errorf("repair shared session index: %w: %s", err, stderr.String())
	}
	if err := json.Unmarshal(output, &report); err != nil {
		return report, fmt.Errorf("decode session index repair: %w", err)
	}
	return report, nil
}
