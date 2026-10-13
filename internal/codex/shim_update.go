package codex

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"time"
)

// RemoteRoutingReady checks the entry SSH clients actually launch, rather than
// the presence of credentials in an isolated account home.
func RemoteRoutingReady() bool {
	entry, err := exec.LookPath("codex")
	return err == nil && sameAsSelf(entry)
}

func installedShimPaths() []string {
	var paths []string
	seen := map[string]bool{}
	for _, dir := range filepath.SplitList(os.Getenv("PATH")) {
		if !filepath.IsAbs(dir) {
			continue
		}
		path := filepath.Join(dir, "codex")
		if !seen[path] && sameAsSelf(path) {
			paths = append(paths, path)
			seen[path] = true
		}
	}
	return paths
}

func restoreUpdatedShims(paths []string) error {
	self, err := os.Executable()
	if err != nil {
		return err
	}
	self, err = filepath.EvalSymlinks(self)
	if err != nil {
		return err
	}
	for _, path := range paths {
		if sameAsSelf(path) {
			continue
		}
		info, err := os.Lstat(path)
		if os.IsNotExist(err) {
			if err := os.Symlink(self, path); err != nil {
				return err
			}
			continue
		}
		if err != nil {
			return fmt.Errorf("inspect CAB entry after Codex update %s: %w", path, err)
		}
		resolved, err := filepath.EvalSymlinks(path)
		if err != nil {
			return err
		}
		if err := executable(resolved); err != nil {
			return err
		}
		backup := path + ".cab-backup-" + time.Now().UTC().Format("20060102T150405.000000000Z")
		if info.Mode()&os.ModeSymlink != 0 {
			destination, err := os.Readlink(path)
			if err != nil {
				return err
			}
			err = os.Symlink(destination, backup)
			if err != nil {
				return err
			}
		} else {
			// Preserve the newly installed inode before atomically replacing
			// the public entry with the CAB shim.
			if err := os.Link(path, backup); err != nil {
				return err
			}
		}
		temp := backup + ".shim"
		if err := os.Symlink(self, temp); err != nil {
			return err
		}
		if err := os.Rename(temp, path); err != nil {
			_ = os.Remove(temp)
			return fmt.Errorf("restore CAB routing after Codex update: %w", err)
		}
	}
	return nil
}
