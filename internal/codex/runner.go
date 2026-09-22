package codex

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const loginStatusTimeout = 10 * time.Second
const loginStatusOutputLimit = 4096
const updateCheckTimeout = 8 * time.Second

var latestCodexVersionURL = "https://registry.npmjs.org/@openai%2fcodex/latest"

type UpdateStatus struct {
	CurrentVersion  string `json:"current_version"`
	LatestVersion   string `json:"latest_version,omitempty"`
	UpdateAvailable bool   `json:"update_available"`
	CheckError      string `json:"check_error,omitempty"`
}

type cappedBuffer struct {
	bytes.Buffer
	limit int
}

func (buffer *cappedBuffer) Write(value []byte) (int, error) {
	written := len(value)
	remaining := buffer.limit - buffer.Len()
	if remaining <= 0 {
		return written, nil
	}
	if len(value) > remaining {
		value = value[:remaining]
	}
	_, err := buffer.Buffer.Write(value)
	return written, err
}

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
	return runOfficial(binary, args, environment(home))
}

func runOfficial(binary string, args []string, env []string) (int, error) {
	cmd := exec.Command(binary, args...)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	cmd.Env = env
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
	err := cmd.Wait()
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

// Update asks the official Codex executable to update its own installation.
// It intentionally goes through the same real-binary resolver as normal runs,
// so a CAB shim never updates itself or another wrapper. CODEX_HOME is cleared
// because the installer metadata belongs to the global CLI installation, not
// to one of CAB's account homes.
func Update() (int, error) {
	binary, err := FindReal("codex")
	if err != nil {
		return 127, err
	}
	return runOfficial(binary, []string{"update"}, globalCodexEnvironment())
}

// CheckUpdate reads the installed official CLI version and compares it with
// the latest published @openai/codex package. A registry failure is returned
// in CheckError so callers can keep the current version visible and decide
// how to present an indeterminate update state.
func CheckUpdate() (UpdateStatus, error) {
	binary, err := FindReal("codex")
	if err != nil {
		return UpdateStatus{}, err
	}
	ctx, cancel := context.WithTimeout(context.Background(), updateCheckTimeout)
	defer cancel()
	current, err := readCodexVersion(ctx, binary)
	if err != nil {
		return UpdateStatus{}, err
	}
	status := UpdateStatus{CurrentVersion: current}
	latest, err := readLatestCodexVersion(ctx)
	if err != nil {
		status.CheckError = err.Error()
		return status, nil
	}
	status.LatestVersion = latest
	status.UpdateAvailable = versionGreater(latest, current)
	return status, nil
}

func globalCodexEnvironment() []string {
	env := make([]string, 0, len(os.Environ()))
	for _, value := range os.Environ() {
		if hasEnvKey(value, "CODEX_HOME") || hasEnvKey(value, "CODEX_THREAD_ID") {
			continue
		}
		env = append(env, value)
	}
	return env
}

func readCodexVersion(ctx context.Context, binary string) (string, error) {
	cmd := exec.CommandContext(ctx, binary, "--version")
	cmd.Env = globalCodexEnvironment()
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		message := strings.TrimSpace(stderr.String())
		if message == "" {
			message = strings.TrimSpace(stdout.String())
		}
		if message == "" {
			message = err.Error()
		}
		return "", fmt.Errorf("codex --version failed: %s", message)
	}
	version, ok := extractVersion(stdout.String())
	if !ok {
		return "", fmt.Errorf("unable to parse Codex version from %q", strings.TrimSpace(stdout.String()))
	}
	return version, nil
}

func readLatestCodexVersion(ctx context.Context) (string, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, latestCodexVersionURL, nil)
	if err != nil {
		return "", err
	}
	request.Header.Set("Accept", "application/json")
	request.Header.Set("User-Agent", "codex-account-bridge")
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		return "", fmt.Errorf("read latest Codex version: %w", err)
	}
	defer response.Body.Close()
	if response.StatusCode < http.StatusOK || response.StatusCode >= http.StatusMultipleChoices {
		return "", fmt.Errorf("read latest Codex version: registry returned HTTP %d", response.StatusCode)
	}
	var payload struct {
		Version string `json:"version"`
	}
	if err := json.NewDecoder(io.LimitReader(response.Body, 1<<20)).Decode(&payload); err != nil {
		return "", fmt.Errorf("decode latest Codex version: %w", err)
	}
	version, ok := extractVersion(payload.Version)
	if !ok {
		return "", fmt.Errorf("registry returned invalid Codex version %q", payload.Version)
	}
	return version, nil
}

func extractVersion(value string) (string, bool) {
	for _, field := range strings.Fields(value) {
		field = strings.Trim(field, "()[]{}:,;")
		field = strings.TrimPrefix(field, "v")
		if _, ok := parseVersion(field); ok {
			return field, true
		}
	}
	return "", false
}

func parseVersion(value string) ([3]int, bool) {
	var parsed [3]int
	core := strings.SplitN(strings.TrimSpace(value), "-", 2)[0]
	parts := strings.Split(core, ".")
	if len(parts) < 2 || len(parts) > 3 {
		return parsed, false
	}
	for index, part := range parts {
		number, err := strconv.Atoi(part)
		if err != nil || number < 0 {
			return parsed, false
		}
		parsed[index] = number
	}
	return parsed, true
}

func versionGreater(left, right string) bool {
	lhs, leftOK := parseVersion(left)
	rhs, rightOK := parseVersion(right)
	if !leftOK || !rightOK {
		return false
	}
	for index := range lhs {
		if lhs[index] != rhs[index] {
			return lhs[index] > rhs[index]
		}
	}
	return false
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
	stdout := cappedBuffer{limit: loginStatusOutputLimit}
	cmd.Stdout = &stdout
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
		if strings.TrimSpace(stdout.String()) == "Not logged in" {
			return false, nil
		}
		return false, fmt.Errorf("official Codex login status failed with exit code %d", exitErr.ExitCode())
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
