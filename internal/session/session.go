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

type stagedHistory struct {
	target string
	stage  string
	shared string
}

var historyDirectoryNames = []string{"sessions", "archived_sessions"}

type LegacyReport struct {
	SourceHome       string `json:"source_home"`
	Sessions         int    `json:"sessions"`
	ArchivedSessions int    `json:"archived_sessions"`
}

func LegacyStatus(cfg config.Config, sourceHome string) (LegacyReport, error) {
	report := LegacyReport{SourceHome: sourceHome}
	if cfg.SharedSessionsDir == "" {
		return report, errors.New("session sharing is not enabled")
	}
	for _, account := range cfg.Accounts {
		if filepath.Clean(account.Home) == filepath.Clean(sourceHome) {
			return report, nil
		}
	}
	counts := []*int{&report.Sessions, &report.ArchivedSessions}
	for index, name := range historyDirectoryNames {
		source := filepath.Join(sourceHome, name)
		shared := sharedHistoryDir(cfg.SharedSessionsDir, name)
		if sameResolvedPath(source, shared) {
			continue
		}
		count, err := pendingRegularFiles(source, shared)
		if err != nil {
			return report, err
		}
		*counts[index] = count
	}
	return report, nil
}

func pendingRegularFiles(sourceRoot, targetRoot string) (int, error) {
	count := 0
	err := filepath.WalkDir(sourceRoot, func(source string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if !entry.Type().IsRegular() {
			return nil
		}
		relative, err := filepath.Rel(sourceRoot, source)
		if err != nil {
			return err
		}
		if _, err := os.Lstat(filepath.Join(targetRoot, relative)); errors.Is(err, fs.ErrNotExist) {
			count++
		} else if err != nil {
			return err
		}
		return nil
	})
	if errors.Is(err, fs.ErrNotExist) {
		return 0, nil
	}
	return count, err
}

func ImportLegacy(paths config.Paths, cfg config.Config, sourceHome string) (LegacyReport, error) {
	report, err := LegacyStatus(cfg, sourceHome)
	if err != nil {
		return report, err
	}
	unlock, err := lock(paths.DataDir)
	if err != nil {
		return report, err
	}
	defer unlock()
	for _, name := range historyDirectoryNames {
		if err := mergeTree(filepath.Join(sourceHome, name), sharedHistoryDir(cfg.SharedSessionsDir, name)); err != nil {
			return report, fmt.Errorf("import legacy %s: %w", name, err)
		}
	}
	return report, nil
}

func Enable(paths config.Paths, cfg *config.Config) error {
	unlock, err := lock(paths.DataDir)
	if err != nil {
		return err
	}
	defer unlock()
	sharedSessions := cfg.SharedSessionsDir
	if sharedSessions == "" {
		sharedSessions = filepath.Join(paths.DataDir, "shared", "sessions")
	}
	for _, name := range historyDirectoryNames {
		shared := sharedHistoryDir(sharedSessions, name)
		if err := secureDir(shared); err != nil {
			return err
		}
		for _, account := range cfg.Accounts {
			source := filepath.Join(account.Home, name)
			if err := mergeTree(source, shared); err != nil {
				return fmt.Errorf("merge %s: %w", source, err)
			}
		}
	}
	stamp := time.Now().UTC().Format("20060102T150405Z")
	changed := []changedLink{}
	for _, name := range historyDirectoryNames {
		shared := sharedHistoryDir(sharedSessions, name)
		for _, account := range cfg.Accounts {
			target := filepath.Join(account.Home, name)
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
					return fmt.Errorf("refusing existing %s symlink: %s", name, target)
				}
				if !info.IsDir() {
					rollback(changed)
					return fmt.Errorf("%s path is not a directory: %s", name, target)
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
	}
	cfg.SharedSessionsDir = sharedSessions
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
	stamp := time.Now().UTC().Format("20060102T150405Z")
	staging := []stagedHistory{}
	for _, name := range historyDirectoryNames {
		shared := sharedHistoryDir(cfg.SharedSessionsDir, name)
		for _, account := range cfg.Accounts {
			target := filepath.Join(account.Home, name)
			info, err := os.Lstat(target)
			if errors.Is(err, fs.ErrNotExist) && name == "archived_sessions" {
				continue
			}
			if err != nil {
				cleanupStaging(staging)
				return err
			}
			if info.Mode()&os.ModeSymlink == 0 {
				if name == "archived_sessions" && info.IsDir() {
					continue // Compatibility with sharing enabled before archived history support.
				}
				cleanupStaging(staging)
				return fmt.Errorf("refusing unexpected non-symlink: %s", target)
			}
			if !sameResolvedPath(target, shared) {
				cleanupStaging(staging)
				return fmt.Errorf("refusing unexpected %s target: %s", name, target)
			}
			stage := filepath.Join(account.Home, ".cab-"+name+"-disable-"+stamp)
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
			if err := mergeTree(shared, stage); err != nil {
				cleanupStaging(staging)
				return err
			}
			staging = append(staging, stagedHistory{target: target, stage: stage, shared: shared})
		}
	}
	changed := []stagedHistory{}
	for _, item := range staging {
		if err := os.Remove(item.target); err != nil {
			rollbackDisable(changed)
			cleanupStaging(staging)
			return err
		}
		if err := os.Rename(item.stage, item.target); err != nil {
			_ = os.Symlink(item.shared, item.target)
			rollbackDisable(changed)
			cleanupStaging(staging)
			return err
		}
		changed = append(changed, item)
	}
	cfg.SharedSessionsDir = ""
	return nil
}

func cleanupStaging(staging []stagedHistory) {
	for _, item := range staging {
		_ = os.RemoveAll(item.stage)
	}
}

func rollbackDisable(items []stagedHistory) {
	for index := len(items) - 1; index >= 0; index-- {
		_ = os.RemoveAll(items[index].target)
		_ = os.Symlink(items[index].shared, items[index].target)
	}
}

func sharedHistoryDir(sharedSessions, name string) string {
	if name == "sessions" {
		return sharedSessions
	}
	return filepath.Join(filepath.Dir(sharedSessions), name)
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
