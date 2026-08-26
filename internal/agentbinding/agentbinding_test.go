package agentbinding

import (
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

type fakeRunner struct {
	calls       [][]string
	failRestart bool
}

func (f *fakeRunner) Run(args ...string) ([]byte, error) {
	f.calls = append(f.calls, append([]string(nil), args...))
	if len(args) > 0 && args[0] == "list-unit-files" {
		return []byte("hermes-gateway-coder.service enabled\nopenclaw-gateway.service enabled\nssh-agent.service static\n"), nil
	}
	if len(args) > 1 && args[0] == "show" {
		return []byte("LoadState=loaded\nActiveState=active\n"), nil
	}
	if len(args) > 0 && args[0] == "restart" && f.failRestart {
		return []byte("restart failed"), errors.New("exit 1")
	}
	return nil, nil
}

func TestListOnlySupportedServicesAndCABBinding(t *testing.T) {
	base := t.TempDir()
	runner := &fakeRunner{}
	m := Manager{ConfigHome: base, Runner: runner}
	path := m.dropInPath("hermes-gateway-coder.service")
	if err := writeState(path, []byte("# Managed by CodexAccountBridge. Do not edit.\n[Service]\nEnvironment=\"CODEX_HOME=/accounts/Foxmail\"\n")); err != nil {
		t.Fatal(err)
	}
	got, err := m.List(map[string]string{"Foxmail": "/accounts/Foxmail"})
	if err != nil {
		t.Fatal(err)
	}
	want := []Binding{{Service: "hermes-gateway-coder.service", Kind: "Hermes", Active: true, Account: "Foxmail"}, {Service: "openclaw-gateway.service", Kind: "OpenClaw", Active: true}}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %#v want %#v", got, want)
	}
}

func TestBindRequiresRestartConfirmation(t *testing.T) {
	m := Manager{ConfigHome: t.TempDir(), Runner: &fakeRunner{}}
	err := m.Bind("openclaw-gateway.service", "/accounts/Foxmail", false)
	if err == nil || !strings.Contains(err.Error(), "confirm-restart-agent") {
		t.Fatalf("unexpected error %v", err)
	}
}

func TestBindWritesOnlyCABDropIn(t *testing.T) {
	base := t.TempDir()
	runner := &fakeRunner{}
	m := Manager{ConfigHome: base, Runner: runner}
	if err := m.Bind("openclaw-gateway.service", `/accounts/Fox "mail"`, true); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(m.dropInPath("openclaw-gateway.service"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), `Environment="CODEX_HOME=/accounts/Fox \"mail\""`) {
		t.Fatalf("unexpected drop-in: %s", data)
	}
	info, _ := os.Stat(m.dropInPath("openclaw-gateway.service"))
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("mode %o", info.Mode().Perm())
	}
}

func TestRejectsUnsupportedAndUnsafeDropIn(t *testing.T) {
	m := Manager{ConfigHome: t.TempDir(), Runner: &fakeRunner{}}
	if err := m.Bind("evil.service", "/accounts/Foxmail", true); err == nil {
		t.Fatal("expected unsupported service rejection")
	}
	path := m.dropInPath("openclaw-gateway.service")
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("elsewhere", path); err != nil {
		t.Fatal(err)
	}
	if err := m.Bind("openclaw-gateway.service", "/accounts/Foxmail", true); err == nil {
		t.Fatal("expected symlink rejection")
	}
}
