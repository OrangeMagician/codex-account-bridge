package codex

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"time"
)

const loginStatusTimeout = 10 * time.Second

func FindReal(binary string) (string, error) {
	if configured := os.Getenv("CAB_REAL_CODEX"); configured != "" {
		if !filepath.IsAbs(configured) {
			return "", errors.New("CAB_REAL_CODEX must be an absolute path")
		}
		path, err := filepath.EvalSymlinks(configured)
		if err != nil {
			return "", err
		}
		path, err = filepath.Abs(path)
		if err != nil {
			return "", err
		}
		if err := executable(path); err != nil {
			return "", fmt.Errorf("CAB_REAL_CODEX: %w", err)
		}
		if sameAsSelf(path) {
			return "", errors.New("CAB_REAL_CODEX points back to cab")
		}
		return path, nil
	}
	self, _ := os.Executable()
	self, _ = filepath.EvalSymlinks(self)
	self, _ = filepath.Abs(self)
	workingDirectory, _ := os.Getwd()
	workingDirectory = worktreeRoot(workingDirectory)
	var shimBackups []string
	for _, dir := range filepath.SplitList(os.Getenv("PATH")) {
		if dir == "" || !filepath.IsAbs(dir) {
			continue
		}
		candidate := filepath.Join(dir, binary)
		if executable(candidate) != nil {
			continue
		}
		real, err := filepath.EvalSymlinks(candidate)
		if err != nil {
			continue
		}
		real, err = filepath.Abs(real)
		if err != nil {
			continue
		}
		if self != "" && real == self {
			backups, _ := filepath.Glob(candidate + ".cab-backup-*")
			shimBackups = append(shimBackups, backups...)
			continue
		}
		if workingDirectory != "" && pathInside(workingDirectory, real) {
			continue
		}
		return real, nil
	}
	sort.Sort(sort.Reverse(sort.StringSlice(shimBackups)))
	for _, candidate := range shimBackups {
		if executable(candidate) != nil {
			continue
		}
		real, err := filepath.EvalSymlinks(candidate)
		if err != nil {
			continue
		}
		real, err = filepath.Abs(real)
		if err != nil || (self != "" && real == self) {
			continue
		}
		if workingDirectory != "" && pathInside(workingDirectory, real) {
			continue
		}
		return real, nil
	}
	return "", fmt.Errorf("official %s executable not found; install it or set CAB_REAL_CODEX", binary)
}

func worktreeRoot(path string) string {
	resolved, err := filepath.EvalSymlinks(path)
	if err != nil {
		return ""
	}
	resolved, err = filepath.Abs(resolved)
	if err != nil {
		return ""
	}
	home, _ := os.UserHomeDir()
	home, _ = filepath.EvalSymlinks(home)
	for candidate := resolved; ; candidate = filepath.Dir(candidate) {
		for _, marker := range []string{".git", "go.mod"} {
			if _, err := os.Lstat(filepath.Join(candidate, marker)); err == nil {
				if candidate != string(filepath.Separator) && filepath.Clean(candidate) != filepath.Clean(home) {
					return candidate
				}
				return ""
			}
		}
		parent := filepath.Dir(candidate)
		if parent == candidate {
			return ""
		}
	}
}

func sameAsSelf(path string) bool {
	self, err := os.Executable()
	if err != nil {
		return false
	}
	self, err = filepath.EvalSymlinks(self)
	if err != nil {
		return false
	}
	path, err = filepath.EvalSymlinks(path)
	if err != nil {
		return false
	}
	return filepath.Clean(self) == filepath.Clean(path)
}

func executable(path string) error {
	info, err := os.Stat(path)
	if err != nil {
		return err
	}
	if info.IsDir() || info.Mode().Perm()&0o111 == 0 {
		return errors.New("not executable")
	}
	if info.Mode().Perm()&0o022 != 0 {
		return errors.New("executable is writable by group or other users")
	}
	return nil
}

func pathInside(parent, child string) bool {
	relative, err := filepath.Rel(parent, child)
	return err == nil && relative != ".." && !strings.HasPrefix(relative, ".."+string(filepath.Separator))
}

func Run(home string, args []string) (int, error) {
	binary, err := FindReal("codex")
	if err != nil {
		return 127, err
	}
	cmd := exec.Command(binary, args...)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	cmd.Env = environment(home)
	signals := make(chan os.Signal, 2)
	signal.Notify(signals, syscall.SIGINT, syscall.SIGTERM, syscall.SIGHUP)
	defer signal.Stop(signals)
	if err := cmd.Start(); err != nil {
		return 127, err
	}
	done := make(chan struct{})
	go func() {
		select {
		case sig := <-signals:
			if cmd.Process != nil {
				_ = cmd.Process.Signal(sig)
			}
		case <-done:
		}
	}()
	err = cmd.Wait()
	close(done)
	if err == nil {
		return 0, nil
	}
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		return exitErr.ExitCode(), nil
	}
	return 1, err
}

func LoggedIn(home string) (bool, error) {
	binary, err := FindReal("codex")
	if err != nil {
		return false, err
	}
	ctx, cancel := context.WithTimeout(context.Background(), loginStatusTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, binary, "login", "status")
	cmd.Env = environment(home)
	cmd.Stdout = nil
	cmd.Stderr = nil
	err = cmd.Run()
	if err == nil {
		return true, nil
	}
	if ctx.Err() != nil {
		return false, errors.New("official Codex login status timed out")
	}
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		return false, nil
	}
	return false, err
}

func environment(home string) []string {
	env := make([]string, 0, len(os.Environ())+1)
	for _, value := range os.Environ() {
		if hasEnvKey(value, "CODEX_HOME") || hasEnvKey(value, "CODEX_THREAD_ID") {
			continue
		}
		env = append(env, value)
	}
	return append(env, "CODEX_HOME="+home)
}

func hasEnvKey(value, key string) bool {
	return len(value) > len(key) && value[:len(key)] == key && value[len(key)] == '='
}
