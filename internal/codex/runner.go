package codex

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"syscall"
)

func FindReal(binary string) (string, error) {
	if configured := os.Getenv("CAB_REAL_CODEX"); configured != "" {
		path, err := filepath.Abs(configured)
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
	for _, dir := range filepath.SplitList(os.Getenv("PATH")) {
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
			continue
		}
		return candidate, nil
	}
	return "", fmt.Errorf("official %s executable not found; install it or set CAB_REAL_CODEX", binary)
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
	return nil
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
