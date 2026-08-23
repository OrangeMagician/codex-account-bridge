package session

import (
	"crypto/sha256"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"time"

	"github.com/OrangeMagician/codex-account-bridge/internal/config"
)

type changedLink struct {
	target string
	backup string
}

func Enable(paths config.Paths, cfg *config.Config) error {
	if cfg.SharedSessionsDir != "" {
		return fmt.Errorf("session sharing is already enabled at %s", cfg.SharedSessionsDir)
	}
	unlock, err := lock(paths.DataDir)
	if err != nil {
		return err
	}
	defer unlock()
	shared := filepath.Join(paths.DataDir, "shared", "sessions")
	if err := secureDir(shared); err != nil {
		return err
	}
	for _, account := range cfg.Accounts {
		source := filepath.Join(account.Home, "sessions")
		if err := mergeTree(source, shared); err != nil {
			return fmt.Errorf("merge %s: %w", source, err)
		}
	}
	stamp := time.Now().UTC().Format("20060102T150405Z")
	changed := []changedLink{}
	for _, account := range cfg.Accounts {
		target := filepath.Join(account.Home, "sessions")
		if err := os.MkdirAll(account.Home, 0o700); err != nil {
			rollback(changed)
			return err
		}
		info, err := os.Lstat(target)
		backup := ""
		if err == nil {
			if info.Mode()&os.ModeSymlink != 0 {
				if sameResolvedPath(target, shared) {
					continue
				}
				rollback(changed)
				return fmt.Errorf("refusing existing sessions symlink: %s", target)
			}
			if !info.IsDir() {
				rollback(changed)
				return fmt.Errorf("sessions path is not a directory: %s", target)
			}
			backup = target + ".cab-backup-" + stamp
			if err := os.Rename(target, backup); err != nil {
				rollback(changed)
				return err
			}
		} else if !errors.Is(err, fs.ErrNotExist) {
			rollback(changed)
			return err
		}
		if err := os.Symlink(shared, target); err != nil {
			if backup != "" {
				_ = os.Rename(backup, target)
			}
			rollback(changed)
			return err
		}
		changed = append(changed, changedLink{target: target, backup: backup})
	}
	cfg.SharedSessionsDir = shared
	return nil
}

func Disable(paths config.Paths, cfg *config.Config) error {
	if cfg.SharedSessionsDir == "" {
		return errors.New("session sharing is not enabled")
	}
	unlock, err := lock(paths.DataDir)
	if err != nil {
		return err
	}
	defer unlock()
	shared := cfg.SharedSessionsDir
	for _, account := range cfg.Accounts {
		target := filepath.Join(account.Home, "sessions")
		info, err := os.Lstat(target)
		if err != nil {
			return err
		}
		if info.Mode()&os.ModeSymlink == 0 {
			return fmt.Errorf("refusing unexpected non-symlink: %s", target)
		}
		if !sameResolvedPath(target, shared) {
			return fmt.Errorf("refusing unexpected sessions target: %s", target)
		}
	}
	stamp := time.Now().UTC().Format("20060102T150405Z")
	staging := make(map[string]string, len(cfg.Accounts))
	for _, account := range cfg.Accounts {
		stage := filepath.Join(account.Home, ".cab-sessions-disable-"+stamp)
		if _, err := os.Lstat(stage); err == nil {
			cleanupStaging(staging)
			return fmt.Errorf("staging path already exists: %s", stage)
		} else if !errors.Is(err, fs.ErrNotExist) {
			cleanupStaging(staging)
			return err
		}
		if err := secureDir(stage); err != nil {
			cleanupStaging(staging)
			return err
		}
		staging[account.Home] = stage
		if err := mergeTree(shared, stage); err != nil {
			cleanupStaging(staging)
			return err
		}
	}
	changed := []string{}
	for _, account := range cfg.Accounts {
		target := filepath.Join(account.Home, "sessions")
		if err := os.Remove(target); err != nil {
			rollbackDisable(changed, shared)
			cleanupStaging(staging)
			return err
		}
		if err := os.Rename(staging[account.Home], target); err != nil {
			_ = os.Symlink(shared, target)
			rollbackDisable(changed, shared)
			cleanupStaging(staging)
			return err
		}
		delete(staging, account.Home)
		changed = append(changed, target)
	}
	cfg.SharedSessionsDir = ""
	return nil
}

func cleanupStaging(staging map[string]string) {
	for _, path := range staging {
		_ = os.RemoveAll(path)
	}
}

func rollbackDisable(targets []string, shared string) {
	for index := len(targets) - 1; index >= 0; index-- {
		_ = os.RemoveAll(targets[index])
		_ = os.Symlink(shared, targets[index])
	}
}

func mergeTree(source, destination string) error {
	info, err := os.Lstat(source)
	if errors.Is(err, fs.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if info.Mode()&os.ModeSymlink != 0 {
		if !sameResolvedPath(source, destination) {
			return fmt.Errorf("refusing source symlink %s", source)
		}
		return nil
	}
	if !info.IsDir() {
		return fmt.Errorf("source is not a directory")
	}
	return filepath.WalkDir(source, func(path string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		relative, err := filepath.Rel(source, path)
		if err != nil {
			return err
		}
		target := filepath.Join(destination, relative)
		if entry.Type()&os.ModeSymlink != 0 {
			return fmt.Errorf("refusing nested symlink %s", path)
		}
		if entry.IsDir() {
			return secureDir(target)
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		if !info.Mode().IsRegular() {
			return fmt.Errorf("refusing non-regular session file %s", path)
		}
		if existing, err := os.Lstat(target); err == nil {
			if !existing.Mode().IsRegular() {
				return fmt.Errorf("destination is not regular: %s", target)
			}
			same, err := sameFile(path, target)
			if err != nil {
				return err
			}
			if !same {
				return fmt.Errorf("session collision at %s", target)
			}
			return nil
		} else if !errors.Is(err, fs.ErrNotExist) {
			return err
		}
		return copyFile(path, target)
	})
}

func copyFile(source, target string) error {
	input, err := os.Open(source)
	if err != nil {
		return err
	}
	defer input.Close()
	output, err := os.OpenFile(target, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return err
	}
	ok := false
	defer func() {
		output.Close()
		if !ok {
			_ = os.Remove(target)
		}
	}()
	if _, err := io.Copy(output, input); err != nil {
		return err
	}
	if err := output.Sync(); err != nil {
		return err
	}
	ok = true
	return nil
}

func sameFile(left, right string) (bool, error) {
	hash := func(path string) ([32]byte, error) {
		file, err := os.Open(path)
		if err != nil {
			return [32]byte{}, err
		}
		defer file.Close()
		digest := sha256.New()
		if _, err := io.Copy(digest, file); err != nil {
			return [32]byte{}, err
		}
		var result [32]byte
		copy(result[:], digest.Sum(nil))
		return result, nil
	}
	a, err := hash(left)
	if err != nil {
		return false, err
	}
	b, err := hash(right)
	return a == b, err
}

func secureDir(path string) error {
	if err := os.MkdirAll(path, 0o700); err != nil {
		return err
	}
	return os.Chmod(path, 0o700)
}

func lock(dataDir string) (func(), error) {
	if err := secureDir(dataDir); err != nil {
		return nil, err
	}
	path := filepath.Join(dataDir, "sessions.lock")
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		if errors.Is(err, fs.ErrExist) {
			return nil, fmt.Errorf("another session operation is active; remove stale lock only after checking processes: %s", path)
		}
		return nil, err
	}
	_, _ = fmt.Fprintf(file, "%d\n", os.Getpid())
	_ = file.Close()
	return func() { _ = os.Remove(path) }, nil
}

func rollback(changes []changedLink) {
	for index := len(changes) - 1; index >= 0; index-- {
		change := changes[index]
		_ = os.Remove(change.target)
		if change.backup != "" {
			_ = os.Rename(change.backup, change.target)
		}
	}
}

func sameResolvedPath(left, right string) bool {
	resolvedLeft, err := filepath.EvalSymlinks(left)
	if err != nil {
		return false
	}
	resolvedRight, err := filepath.EvalSymlinks(right)
	if err != nil {
		return false
	}
	return filepath.Clean(resolvedLeft) == filepath.Clean(resolvedRight)
}
