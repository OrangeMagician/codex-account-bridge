package agentbinding

import (
	"bytes"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

const dropInName = "50-cab-account.conf"
const managedHeader = "# Managed by CodexAccountBridge. Do not edit.\n"

var supportedUnit = regexp.MustCompile(`^(hermes-agent-bridge|hermes-gateway(?:-[A-Za-z0-9_.@-]+)?|openclaw-gateway)\.service$`)

type Binding struct {
	Service string `json:"service"`
	Kind    string `json:"kind"`
	Active  bool   `json:"active"`
	Account string `json:"account,omitempty"`
}

type Runner interface {
	Run(args ...string) ([]byte, error)
}

type SystemctlRunner struct{}

func (SystemctlRunner) Run(args ...string) ([]byte, error) {
	cmd := exec.Command("systemctl", append([]string{"--user"}, args...)...)
	return cmd.CombinedOutput()
}

type Manager struct {
	ConfigHome string
	Runner     Runner
}

func DefaultManager() (Manager, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return Manager{}, err
	}
	base := os.Getenv("XDG_CONFIG_HOME")
	if base == "" {
		base = filepath.Join(home, ".config")
	}
	return Manager{ConfigHome: base, Runner: SystemctlRunner{}}, nil
}

func (m Manager) List(accountHomes map[string]string) ([]Binding, error) {
	out, err := m.Runner.Run("list-unit-files", "--type=service", "--no-legend", "--no-pager")
	if err != nil {
		return nil, commandError("discover user services", out, err)
	}
	var result []Binding
	seen := map[string]bool{}
	for _, line := range strings.Split(string(out), "\n") {
		fields := strings.Fields(line)
		if len(fields) == 0 || !supportedUnit.MatchString(fields[0]) || seen[fields[0]] {
			continue
		}
		unit := fields[0]
		seen[unit] = true
		active, err := m.isActive(unit)
		if err != nil {
			return nil, err
		}
		account, err := m.boundAccount(unit, accountHomes)
		if err != nil {
			return nil, err
		}
		result = append(result, Binding{Service: unit, Kind: kind(unit), Active: active, Account: account})
	}
	sort.Slice(result, func(i, j int) bool { return result[i].Service < result[j].Service })
	return result, nil
}

func (m Manager) Bind(unit, home string, confirmRestart bool) error {
	if err := validateUnit(unit); err != nil {
		return err
	}
	active, err := m.ensureInstalled(unit)
	if err != nil {
		return err
	}
	if active && !confirmRestart {
		return errors.New("service is active; pass --confirm-restart-agent after saving agent tasks")
	}
	if !filepath.IsAbs(home) || strings.ContainsAny(home, "\r\n\x00") {
		return errors.New("account CODEX_HOME must be a safe absolute path")
	}
	content := []byte(managedHeader + "[Service]\nEnvironment=\"CODEX_HOME=" + escapeSystemd(home) + "\"\n")
	return m.update(unit, content, active)
}

func (m Manager) Unbind(unit string, confirmRestart bool) error {
	if err := validateUnit(unit); err != nil {
		return err
	}
	active, err := m.ensureInstalled(unit)
	if err != nil {
		return err
	}
	if active && !confirmRestart {
		return errors.New("service is active; pass --confirm-restart-agent after saving agent tasks")
	}
	return m.update(unit, nil, active)
}

func (m Manager) ensureInstalled(unit string) (bool, error) {
	out, err := m.Runner.Run("show", unit, "--property=LoadState", "--property=ActiveState", "--no-pager")
	if err != nil {
		return false, commandError("inspect "+unit, out, err)
	}
	text := string(out)
	if !strings.Contains(text, "LoadState=loaded") {
		return false, fmt.Errorf("supported service %s is not installed", unit)
	}
	return strings.Contains(text, "ActiveState=active"), nil
}

func (m Manager) isActive(unit string) (bool, error) { return m.ensureInstalled(unit) }

func (m Manager) boundAccount(unit string, homes map[string]string) (string, error) {
	data, err := readSafe(m.dropInPath(unit))
	if errors.Is(err, fs.ErrNotExist) {
		return "", nil
	}
	if err != nil {
		return "", err
	}
	prefix := "Environment=\"CODEX_HOME="
	for _, line := range strings.Split(string(data), "\n") {
		if strings.HasPrefix(line, prefix) && strings.HasSuffix(line, "\"") {
			home := unescapeSystemd(strings.TrimSuffix(strings.TrimPrefix(line, prefix), "\""))
			for name, candidate := range homes {
				if filepath.Clean(candidate) == filepath.Clean(home) {
					return name, nil
				}
			}
			return "", nil
		}
	}
	return "", fmt.Errorf("CAB agent binding has an invalid format: %s", m.dropInPath(unit))
}

func (m Manager) update(unit string, next []byte, active bool) error {
	path := m.dropInPath(unit)
	previous, readErr := readSafe(path)
	existed := readErr == nil
	if readErr != nil && !errors.Is(readErr, fs.ErrNotExist) {
		return readErr
	}
	if existed && !bytes.HasPrefix(previous, []byte(managedHeader)) {
		return fmt.Errorf("refusing to replace a drop-in not owned by CAB: %s", path)
	}
	if next == nil && !existed {
		return nil
	}
	if err := writeState(path, next); err != nil {
		return err
	}
	rollback := func() {
		_ = writeState(path, func() []byte {
			if existed {
				return previous
			}
			return nil
		}())
		_, _ = m.Runner.Run("daemon-reload")
		if active {
			_, _ = m.Runner.Run("restart", unit)
		}
	}
	if out, err := m.Runner.Run("daemon-reload"); err != nil {
		rollback()
		return commandError("reload user services", out, err)
	}
	if active {
		if out, err := m.Runner.Run("restart", unit); err != nil {
			rollback()
			return commandError("restart "+unit, out, err)
		}
	}
	return nil
}

func (m Manager) dropInPath(unit string) string {
	return filepath.Join(m.ConfigHome, "systemd", "user", unit+".d", dropInName)
}

func writeState(path string, data []byte) error {
	dir := filepath.Dir(path)
	if info, err := os.Lstat(dir); err == nil {
		if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
			return fmt.Errorf("refusing unsafe drop-in directory: %s", dir)
		}
	} else if !errors.Is(err, fs.ErrNotExist) {
		return err
	} else if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	if data == nil {
		if err := os.Remove(path); err != nil && !errors.Is(err, fs.ErrNotExist) {
			return err
		}
		return nil
	}
	if _, err := readSafe(path); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return err
	}
	tmp, err := os.CreateTemp(dir, ".cab-agent-*.tmp")
	if err != nil {
		return err
	}
	name := tmp.Name()
	defer os.Remove(name)
	if err := tmp.Chmod(0o600); err != nil {
		tmp.Close()
		return err
	}
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(name, path)
}

func readSafe(path string) ([]byte, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return nil, err
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
		return nil, fmt.Errorf("refusing unsafe agent binding: %s", path)
	}
	return os.ReadFile(path)
}

func validateUnit(unit string) error {
	if !supportedUnit.MatchString(unit) {
		return fmt.Errorf("unsupported agent service %q", unit)
	}
	return nil
}
func kind(unit string) string {
	if strings.HasPrefix(unit, "openclaw-") {
		return "OpenClaw"
	}
	if unit == "hermes-agent-bridge.service" {
		return "Hermes Bridge"
	}
	return "Hermes"
}
func escapeSystemd(value string) string {
	return strings.NewReplacer(`\`, `\\`, `"`, `\"`).Replace(value)
}
func unescapeSystemd(value string) string {
	return strings.NewReplacer(`\"`, `"`, `\\`, `\`).Replace(value)
}
func commandError(action string, out []byte, err error) error {
	message := strings.TrimSpace(string(bytes.TrimSpace(out)))
	if message == "" {
		message = err.Error()
	}
	return fmt.Errorf("%s: %s", action, message)
}
