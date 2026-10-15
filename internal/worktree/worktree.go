// Package worktree manages only CAB-created Git worktrees, not Codex's internal
// worktree registry. No hooks, branch resets, force removal or trust changes.
package worktree

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
	"time"
)

type Entry struct {
	ID         string    `json:"id"`
	Account    string    `json:"account"`
	Repository string    `json:"repository"`
	Path       string    `json:"path"`
	Ref        string    `json:"ref"`
	CreatedAt  time.Time `json:"created_at"`
	Exists     bool      `json:"exists"`
}

var idPattern = regexp.MustCompile(`^[a-f0-9]{32}$`)

func safeDirectory(path string, create bool) error {
	if !filepath.IsAbs(path) {
		return errors.New("directory must be absolute")
	}
	for p := filepath.Clean(path); ; p = filepath.Dir(p) {
		info, err := os.Lstat(p)
		if os.IsNotExist(err) && create {
			if p == filepath.Dir(p) {
				return err
			}
			continue
		}
		if err != nil {
			return err
		}
		if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
			return errors.New("refusing symlink or non-directory worktree path")
		}
		if p == filepath.Dir(p) {
			break
		}
	}
	if create {
		return os.MkdirAll(path, 0700)
	}
	return nil
}

func registry(dataDir string, create bool) (string, error) {
	if err := safeDirectory(dataDir, false); err != nil {
		return "", err
	}
	root := filepath.Join(dataDir, "worktrees")
	if !create {
		if _, err := os.Lstat(root); os.IsNotExist(err) {
			return root, nil
		}
	}
	if err := safeDirectory(root, create); err != nil {
		return "", err
	}
	if info, err := os.Stat(root); err != nil || info.Mode().Perm()&0077 != 0 {
		return "", errors.New("worktree registry must be private (0700)")
	}
	return root, nil
}

func git(args ...string) ([]byte, error) {
	path := ""
	for _, candidate := range []string{"/usr/bin/git", "/bin/git"} {
		if info, err := os.Stat(candidate); err == nil && info.Mode().IsRegular() && info.Mode().Perm()&0111 != 0 {
			path = candidate
			break
		}
	}
	if path == "" {
		return nil, errors.New("Git is not available in a trusted system location")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, path, append([]string{"-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false"}, args...)...)
	for _, value := range os.Environ() {
		if !strings.HasPrefix(value, "GIT_") {
			cmd.Env = append(cmd.Env, value)
		}
	}
	cmd.Env = append(cmd.Env, "GIT_TERMINAL_PROMPT=0", "GIT_OPTIONAL_LOCKS=0")
	var output limitedOutput
	cmd.Stdout = &output
	cmd.Stderr = io.Discard
	err := cmd.Run()
	if err != nil {
		return nil, errors.New("Git operation failed; check repository, ref and worktree status")
	}
	if output.overflow {
		return nil, errors.New("Git output exceeds safe limit")
	}
	return output.Bytes(), nil
}

type limitedOutput struct {
	bytes.Buffer
	overflow bool
}

func (b *limitedOutput) Write(data []byte) (int, error) {
	n := len(data)
	remaining := (1 << 20) - b.Len()
	if n > remaining {
		b.overflow = true
		data = data[:remaining]
	}
	_, _ = b.Buffer.Write(data)
	return n, nil
}

func Create(dataDir, account, repository, ref string) (Entry, error) {
	if err := safeDirectory(repository, false); err != nil {
		return Entry{}, err
	}
	if ref == "" {
		ref = "HEAD"
	}
	if len(ref) > 256 || strings.HasPrefix(ref, "-") || strings.ContainsAny(ref, "\x00\r\n") {
		return Entry{}, errors.New("invalid Git ref")
	}
	root, err := registry(dataDir, true)
	if err != nil {
		return Entry{}, err
	}
	bare, err := git("-C", repository, "rev-parse", "--is-bare-repository")
	if err != nil || strings.TrimSpace(string(bare)) != "false" {
		return Entry{}, errors.New("select a non-bare Git repository")
	}
	commit, err := git("-C", repository, "rev-parse", "--verify", "--end-of-options", ref+"^{commit}")
	if err != nil {
		return Entry{}, err
	}
	paths, err := git("-C", repository, "ls-tree", "-r", "--name-only", "-z", strings.TrimSpace(string(commit)))
	if err != nil {
		return Entry{}, err
	}
	if err = validateCheckoutPaths(paths); err != nil {
		return Entry{}, err
	}
	bytes := make([]byte, 16)
	if _, err = rand.Read(bytes); err != nil {
		return Entry{}, err
	}
	id := hex.EncodeToString(bytes)
	entry := Entry{ID: id, Account: account, Repository: repository, Path: filepath.Join(root, id), Ref: ref, CreatedAt: time.Now().UTC(), Exists: true}
	if _, err = git("-C", repository, "worktree", "add", "--detach", entry.Path, strings.TrimSpace(string(commit))); err != nil {
		return Entry{}, err
	}
	// A new checkout inherits no CAB project trust and never executes hooks.
	if err = os.Chmod(entry.Path, 0700); err != nil {
		return Entry{}, err
	}
	data, _ := json.Marshal(entry)
	f, err := os.OpenFile(filepath.Join(root, id+".json"), os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return Entry{}, fmt.Errorf("worktree created at %s but registration failed", entry.Path)
	}
	_, err = f.Write(data)
	if err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err == nil {
		err = closeErr
	}
	if err != nil {
		return Entry{}, fmt.Errorf("worktree created at %s but registration failed", entry.Path)
	}
	return entry, nil
}

func List(dataDir, account string) ([]Entry, error) {
	root, err := registry(dataDir, false)
	if err != nil {
		return nil, err
	}
	files, err := os.ReadDir(root)
	if os.IsNotExist(err) {
		return []Entry{}, nil
	}
	if err != nil {
		return nil, err
	}
	result := []Entry{}
	for _, file := range files {
		id := strings.TrimSuffix(file.Name(), ".json")
		if file.Name() != id+".json" || !idPattern.MatchString(id) {
			continue
		}
		path := filepath.Join(root, file.Name())
		info, err := os.Lstat(path)
		if err != nil {
			return nil, err
		}
		if !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0 || info.Size() > 16384 {
			return nil, errors.New("unsafe worktree registration")
		}
		// Do not follow a registration swapped to a symlink between checks.
		fd, err := syscall.Open(path, syscall.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_CLOEXEC|syscall.O_NONBLOCK, 0)
		if err != nil {
			return nil, err
		}
		f := os.NewFile(uintptr(fd), path)
		opened, statErr := f.Stat()
		if statErr != nil || !opened.Mode().IsRegular() {
			_ = f.Close()
			return nil, errors.New("unsafe worktree registration")
		}
		data, err := io.ReadAll(io.LimitReader(f, 16385))
		_ = f.Close()
		if err != nil || len(data) > 16384 {
			return nil, errors.New("invalid worktree registration size")
		}
		var e Entry
		if err = json.Unmarshal(data, &e); err != nil {
			return nil, errors.New("invalid worktree registration")
		}
		if e.ID != id || e.Path != filepath.Join(root, id) || !filepath.IsAbs(e.Repository) {
			return nil, errors.New("worktree registration escapes managed root")
		}
		if e.Account != account {
			continue
		}
		if _, err = os.Lstat(e.Path); os.IsNotExist(err) {
			e.Exists = false
		} else if err != nil {
			return nil, err
		} else {
			if err = safeDirectory(e.Path, false); err != nil {
				return nil, err
			}
			e.Exists = true
		}
		result = append(result, e)
	}
	return result, nil
}

func validateCheckoutPaths(names []byte) error {
	for _, name := range strings.Split(string(names), "\x00") {
		if strings.EqualFold(filepath.Base(name), "auth.json") {
			return errors.New("refusing to copy a tracked authentication storage file into a worktree")
		}
	}
	return nil
}

func Remove(dataDir, account, id string) error {
	if !idPattern.MatchString(id) {
		return errors.New("invalid managed worktree ID")
	}
	entries, err := List(dataDir, account)
	if err != nil {
		return err
	}
	for _, e := range entries {
		if e.ID != id {
			continue
		}
		if !e.Exists {
			return errors.New("worktree is missing; inspect the Git registry before cleanup")
		}
		if err = safeDirectory(e.Repository, false); err != nil {
			return err
		}
		status, err := git("-C", e.Path, "status", "--porcelain", "--untracked-files=all")
		if err != nil {
			return err
		}
		if len(status) != 0 {
			return errors.New("worktree has local changes; save them before removing it")
		}
		// Keep committed work reachable even when this checkout has a detached HEAD.
		head, err := git("-C", e.Path, "rev-parse", "HEAD")
		if err != nil {
			return err
		}
		if _, err = git("-C", e.Repository, "update-ref", "refs/cab/worktree-archives/"+e.ID, strings.TrimSpace(string(head))); err != nil {
			return err
		}
		if _, err = git("-C", e.Repository, "worktree", "remove", e.Path); err != nil {
			return err
		}
		return os.Remove(filepath.Join(dataDir, "worktrees", id+".json"))
	}
	return errors.New("worktree is not registered to the selected account")
}
