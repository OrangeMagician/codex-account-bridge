// Package maintenance handles only CAB-created backups of approved portable
// workspace files. It never opens credential files or accepts caller paths.
package maintenance

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"time"

	"github.com/OrangeMagician/codex-account-bridge/internal/config"
)

type Backup struct {
	ID        string    `json:"id"`
	Account   string    `json:"account"`
	Path      string    `json:"path"`
	Target    string    `json:"target"`
	Bytes     int64     `json:"bytes"`
	CreatedAt time.Time `json:"created_at"`
	Kind      string    `json:"kind"`
	Safe      bool      `json:"safe"`
	Problem   string    `json:"problem,omitempty"`
}

type Preview struct {
	Backup  Backup `json:"backup"`
	Action  string `json:"action"`
	Allowed bool   `json:"allowed"`
	Reason  string `json:"reason"`
}

var allowed = map[string]bool{
	"sessions": true, "archived_sessions": true, "attachments": true, "generated_images": true,
	"visualizations": true, "prompts": true, "skills": true, "rules": true, "memories": true,
	"vendor_imports": true, "AGENTS.md": true, "history.jsonl": true, "session_index.jsonl": true,
	"transcription-history.jsonl": true, ".codex-global-state.json": true, "state_5.sqlite": true,
	"thread_history_1.sqlite": true, "goals_1.sqlite": true, "memories_1.sqlite": true, "queue_1.sqlite": true,
	"codex-dev.db": true,
}

func safeComponents(path string) error {
	path = filepath.Clean(path)
	for current := path; ; current = filepath.Dir(current) {
		info, err := os.Lstat(current)
		if err != nil {
			return err
		}
		if info.Mode()&os.ModeSymlink != 0 {
			return errors.New("symbolic links are not allowed")
		}
		if current == filepath.Dir(current) {
			break
		}
	}
	return nil
}

func inspectTree(path string) (int64, error) {
	if err := safeComponents(path); err != nil {
		return 0, err
	}
	var size int64
	count := 0
	err := filepath.WalkDir(path, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		count++
		if count > 100_000 {
			return errors.New("backup contains too many files")
		}
		// Names alone are enough to reject credentials, before opening anything.
		if strings.EqualFold(entry.Name(), "auth.json") {
			return errors.New("credential files are excluded")
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		if !info.Mode().IsRegular() && !info.IsDir() {
			return errors.New("backup contains a symlink or special file")
		}
		if info.Mode().IsRegular() {
			size += info.Size()
		}
		return nil
	})
	return size, err
}

func List(paths config.Paths, cfg config.Config) ([]Backup, error) {
	result := []Backup{}
	seen := map[string]bool{}
	add := func(path, target, account string) {
		if seen[path] {
			return
		}
		seen[path] = true
		info, err := os.Lstat(path)
		if err != nil {
			return
		}
		size, err := inspectTree(path)
		sum := sha256.Sum256([]byte(fmt.Sprintf("%s:%d:%d", path, info.ModTime().UnixNano(), info.Size())))
		item := Backup{ID: hex.EncodeToString(sum[:16]), Account: account, Path: path, Target: target, Bytes: size, CreatedAt: info.ModTime(), Kind: "file", Safe: err == nil}
		if info.IsDir() {
			item.Kind = "directory"
		}
		if strings.HasSuffix(target, ".sqlite") || strings.HasSuffix(target, ".db") {
			item.Kind = "database"
		}
		if err != nil {
			item.Problem = err.Error()
		}
		result = append(result, item)
	}
	for _, account := range cfg.Accounts {
		for _, directory := range []string{account.Home, filepath.Join(account.Home, "sqlite")} {
			if safeComponents(directory) != nil {
				continue
			}
			entries, err := os.ReadDir(directory)
			if err != nil {
				continue
			}
			for _, entry := range entries {
				base, suffix, ok := strings.Cut(entry.Name(), ".cab-backup-")
				if !ok || suffix == "" || !allowed[base] {
					continue
				}
				add(filepath.Join(directory, entry.Name()), filepath.Join(directory, base), account.Name)
			}
		}
	}
	if safeComponents(paths.DataDir) == nil {
		directories, _ := os.ReadDir(paths.DataDir)
		for _, directory := range directories {
			if !directory.IsDir() || !strings.HasPrefix(directory.Name(), "index-backup-") {
				continue
			}
			root := filepath.Join(paths.DataDir, directory.Name())
			if safeComponents(root) != nil {
				continue
			}
			files, _ := os.ReadDir(root)
			for _, file := range files {
				var matches []config.Account
				for _, account := range cfg.Accounts {
					if file.Name() == filepath.Base(account.Home)+"-state_5.sqlite" {
						matches = append(matches, account)
					}
				}
				// Ambiguous legacy backups are never mapped to an arbitrary account.
				if len(matches) == 1 {
					add(filepath.Join(root, file.Name()), filepath.Join(matches[0].Home, "state_5.sqlite"), matches[0].Name)
				}
			}
		}
	}
	sort.Slice(result, func(i, j int) bool { return result[i].CreatedAt.After(result[j].CreatedAt) })
	return result, nil
}

func Plan(paths config.Paths, cfg config.Config, id, action string) (Preview, error) {
	if action != "restore" && action != "delete" {
		return Preview{}, errors.New("action must be restore or delete")
	}
	items, err := List(paths, cfg)
	if err != nil {
		return Preview{}, err
	}
	for _, item := range items {
		if item.ID != id {
			continue
		}
		plan := Preview{Backup: item, Action: action, Allowed: item.Safe, Reason: item.Problem}
		if action == "restore" && plan.Allowed {
			if err := safeComponents(filepath.Dir(item.Target)); err != nil {
				plan.Allowed = false
				plan.Reason = err.Error()
			}
			if _, err := os.Lstat(item.Target); err == nil {
				if _, err := inspectTree(item.Target); err != nil {
					plan.Allowed = false
					plan.Reason = "Target: " + err.Error()
				}
			} else if !errors.Is(err, fs.ErrNotExist) {
				plan.Allowed = false
				plan.Reason = err.Error()
			}
			if cfg.SharedSessionsDir != "" && (filepath.Base(item.Target) == "sessions" || filepath.Base(item.Target) == "archived_sessions") {
				plan.Allowed = false
				plan.Reason = "Disable session sharing before restoring an account's independent history"
			}
			if plan.Allowed && item.Kind == "database" {
				if err := databaseOperation(item.Path, "", "check"); err != nil {
					plan.Allowed = false
					plan.Reason = err.Error()
				}
			}
			if plan.Allowed {
				plan.Reason = "Quit Codex before restoring. The current target will be backed up first."
			}
		} else if action == "delete" && plan.Allowed {
			plan.Reason = "Permanently remove only this backup; the current workspace is unchanged."
		}
		return plan, nil
	}
	return Preview{}, errors.New("backup changed or no longer exists; refresh the list")
}

func Apply(plan Preview) (string, error) {
	if !plan.Allowed {
		return "", errors.New(plan.Reason)
	}
	// Revalidate immediately before mutation; symlinks and credentials fail closed.
	if _, err := inspectTree(plan.Backup.Path); err != nil {
		return "", err
	}
	if plan.Action == "delete" {
		return "", os.RemoveAll(plan.Backup.Path)
	}
	target := plan.Backup.Target
	if err := safeComponents(filepath.Dir(target)); err != nil {
		return "", err
	}
	rollback := target + fmt.Sprintf(".cab-backup-%d", time.Now().UnixNano())
	if plan.Backup.Kind == "database" {
		return rollback, databaseOperation(plan.Backup.Path, target, rollback)
	}
	stage := target + fmt.Sprintf(".cab-restore-%d", time.Now().UnixNano())
	if err := copyTree(plan.Backup.Path, stage); err != nil {
		os.RemoveAll(stage)
		return "", err
	}
	defer os.RemoveAll(stage)
	existed := false
	if _, err := os.Lstat(target); err == nil {
		if _, err := inspectTree(target); err != nil {
			return "", err
		}
		if err := os.Rename(target, rollback); err != nil {
			return "", err
		}
		existed = true
	} else if !errors.Is(err, fs.ErrNotExist) {
		return "", err
	}
	if err := os.Rename(stage, target); err != nil {
		if existed {
			err = errors.Join(err, os.Rename(rollback, target))
		}
		return "", err
	}
	if !existed {
		return "", nil
	}
	return rollback, nil
}

func copyTree(source, target string) error {
	return filepath.WalkDir(source, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if strings.EqualFold(entry.Name(), "auth.json") {
			return errors.New("credential files are excluded")
		}
		info, err := os.Lstat(path)
		if err != nil {
			return err
		}
		relative, err := filepath.Rel(source, path)
		if err != nil {
			return err
		}
		destination := filepath.Join(target, relative)
		if info.IsDir() {
			return os.Mkdir(destination, 0700)
		}
		if !info.Mode().IsRegular() {
			return errors.New("unsafe backup item")
		}
		fd, err := syscall.Open(path, syscall.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
		if err != nil {
			return err
		}
		input := os.NewFile(uintptr(fd), path)
		defer input.Close()
		opened, err := input.Stat()
		if err != nil || !opened.Mode().IsRegular() || !os.SameFile(info, opened) {
			return errors.New("backup changed during restore")
		}
		output, err := os.OpenFile(destination, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600|(info.Mode().Perm()&0100))
		if err != nil {
			return err
		}
		_, copyErr := io.Copy(output, input)
		syncErr := output.Sync()
		closeErr := output.Close()
		return errors.Join(copyErr, syncErr, closeErr)
	})
}

func databaseOperation(source, target, operation string) error {
	python := ""
	for _, candidate := range []string{"/usr/bin/python3", "/bin/python3", "/opt/homebrew/bin/python3"} {
		if info, err := os.Stat(candidate); err == nil && info.Mode().IsRegular() {
			python = candidate
			break
		}
	}
	if python == "" {
		return errors.New("Python with SQLite is required")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 120*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, python, "-I", "-c", databaseRestoreScript, source, target, operation)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("database preflight/restore failed: %w: %s", err, output)
	}
	return nil
}

const databaseRestoreScript = `
import os, sqlite3, sys
from pathlib import Path
from contextlib import closing
source, target, operation = sys.argv[1:]
for name in (source, target):
    if not name: continue
    p = Path(name)
    for component in (p, *p.parents):
        if component.is_symlink(): raise ValueError("symlink rejected")
    for suffix in ("-wal", "-shm"):
        p = Path(name + suffix)
        if p.is_symlink() or (p.exists() and not p.is_file()): raise ValueError("unsafe SQLite sidecar")
with closing(sqlite3.connect(Path(source).as_uri()+"?mode=ro",uri=True)) as src:
    if src.execute("PRAGMA quick_check").fetchone()[0] != "ok": raise ValueError("backup integrity check failed")
    if operation != "check":
        existed = Path(target).exists()
        if existed:
            fd = os.open(operation, os.O_CREAT|os.O_EXCL|os.O_WRONLY, 0o600); os.close(fd)
            with closing(sqlite3.connect(Path(target).as_uri()+"?mode=ro",uri=True)) as current, closing(sqlite3.connect(operation)) as rollback:
                current.backup(rollback)
        with closing(sqlite3.connect(target)) as dst:
            src.backup(dst)
        os.chmod(target, 0o600)
`
