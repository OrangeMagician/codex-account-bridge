package app

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"

	"github.com/OrangeMagician/codex-account-bridge/internal/config"
)

func TestAccountLifecyclePreservesHomeOnRemove(t *testing.T) {
	root := t.TempDir()
	t.Setenv("CAB_CONFIG_HOME", filepath.Join(root, "config"))
	t.Setenv("CAB_DATA_HOME", filepath.Join(root, "data"))
	if code, err := Run([]string{"cab", "init"}, "test"); err != nil || code != 0 {
		t.Fatalf("init: code=%d err=%v", code, err)
	}
	if code, err := Run([]string{"cab", "account", "add", "work"}, "test"); err != nil || code != 0 {
		t.Fatalf("add: code=%d err=%v", code, err)
	}
	paths, _ := config.DefaultPaths()
	cfg, err := config.Load(paths)
	if err != nil {
		t.Fatal(err)
	}
	account, ok := cfg.Find("work")
	if !ok {
		t.Fatal("missing account")
	}
	marker := filepath.Join(account.Home, "keep-me")
	if err := os.WriteFile(marker, []byte("data"), 0o600); err != nil {
		t.Fatal(err)
	}
	if code, err := Run([]string{"cab", "account", "remove", "work"}, "test"); err != nil || code != 0 {
		t.Fatalf("remove: code=%d err=%v", code, err)
	}
	if _, err := os.Stat(marker); err != nil {
		t.Fatalf("account files were deleted: %v", err)
	}
}

func TestSessionEnableRequiresExplicitAcknowledgements(t *testing.T) {
	root := t.TempDir()
	t.Setenv("CAB_CONFIG_HOME", filepath.Join(root, "config"))
	t.Setenv("CAB_DATA_HOME", filepath.Join(root, "data"))
	_, _ = Run([]string{"cab", "init"}, "test")
	_, _ = Run([]string{"cab", "account", "add", "one"}, "test")
	_, _ = Run([]string{"cab", "account", "add", "two"}, "test")
	if code, err := Run([]string{"cab", "sessions", "enable", "--confirm-codex-stopped"}, "test"); err == nil || code != 2 {
		t.Fatalf("expected acknowledgement failure, code=%d err=%v", code, err)
	}
}

func TestRotationCommandsAreOptInAndOrdered(t *testing.T) {
	root := t.TempDir()
	t.Setenv("CAB_CONFIG_HOME", filepath.Join(root, "config"))
	t.Setenv("CAB_DATA_HOME", filepath.Join(root, "data"))
	_, _ = Run([]string{"cab", "init"}, "test")
	_, _ = Run([]string{"cab", "account", "add", "one"}, "test")
	_, _ = Run([]string{"cab", "account", "add", "two"}, "test")
	if code, err := Run([]string{"cab", "rotation", "configure", "--accounts", "two,one"}, "test"); err != nil || code != 0 {
		t.Fatalf("configure: code=%d err=%v", code, err)
	}
	paths, _ := config.DefaultPaths()
	cfg, err := config.Load(paths)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Rotation.Enabled {
		t.Fatal("configure must not implicitly enable rotation")
	}
	if code, err := Run([]string{"cab", "rotation", "enable"}, "test"); err != nil || code != 0 {
		t.Fatalf("enable: code=%d err=%v", code, err)
	}
	cfg, _ = config.Load(paths)
	first, err := cfg.NextRotationAccount()
	if err != nil || first.Name != "two" {
		t.Fatalf("first configured account = %q, err=%v", first.Name, err)
	}
}

func TestRotationEnableRequiresTwoAccounts(t *testing.T) {
	root := t.TempDir()
	t.Setenv("CAB_CONFIG_HOME", filepath.Join(root, "config"))
	t.Setenv("CAB_DATA_HOME", filepath.Join(root, "data"))
	_, _ = Run([]string{"cab", "init"}, "test")
	_, _ = Run([]string{"cab", "account", "add", "one"}, "test")
	_, _ = Run([]string{"cab", "rotation", "configure", "--accounts", "one"}, "test")
	if code, err := Run([]string{"cab", "rotation", "enable"}, "test"); err == nil || code != 2 {
		t.Fatalf("expected enable rejection, code=%d err=%v", code, err)
	}
}

func TestRunRotationAdvancesButExplicitAccountDoesNot(t *testing.T) {
	trueBinary, err := exec.LookPath("true")
	if err != nil {
		t.Skip("true executable is unavailable")
	}
	root := t.TempDir()
	t.Setenv("CAB_CONFIG_HOME", filepath.Join(root, "config"))
	t.Setenv("CAB_DATA_HOME", filepath.Join(root, "data"))
	t.Setenv("CAB_REAL_CODEX", trueBinary)
	_, _ = Run([]string{"cab", "init"}, "test")
	_, _ = Run([]string{"cab", "account", "add", "one"}, "test")
	_, _ = Run([]string{"cab", "account", "add", "two"}, "test")
	_, _ = Run([]string{"cab", "rotation", "configure", "--accounts", "two,one"}, "test")
	_, _ = Run([]string{"cab", "rotation", "enable"}, "test")

	if code, err := Run([]string{"cab", "run", "--", "exec", "test"}, "test"); err != nil || code != 0 {
		t.Fatalf("rotated run: code=%d err=%v", code, err)
	}
	paths, _ := config.DefaultPaths()
	cfg, err := config.Load(paths)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Rotation.NextIndex != 1 {
		t.Fatalf("next index after rotated run = %d, want 1", cfg.Rotation.NextIndex)
	}
	if code, err := Run([]string{"cab", "run", "--account", "one", "--", "exec", "test"}, "test"); err != nil || code != 0 {
		t.Fatalf("explicit run: code=%d err=%v", code, err)
	}
	cfg, _ = config.Load(paths)
	if cfg.Rotation.NextIndex != 1 {
		t.Fatalf("explicit account advanced rotation to %d", cfg.Rotation.NextIndex)
	}
}

func TestRunRotationRejectsSymlinkLock(t *testing.T) {
	root := t.TempDir()
	t.Setenv("CAB_CONFIG_HOME", filepath.Join(root, "config"))
	t.Setenv("CAB_DATA_HOME", filepath.Join(root, "data"))
	_, _ = Run([]string{"cab", "init"}, "test")
	_, _ = Run([]string{"cab", "account", "add", "one"}, "test")
	_, _ = Run([]string{"cab", "account", "add", "two"}, "test")
	_, _ = Run([]string{"cab", "rotation", "configure", "--accounts", "one,two"}, "test")
	_, _ = Run([]string{"cab", "rotation", "enable"}, "test")
	paths, _ := config.DefaultPaths()
	target := filepath.Join(root, "outside-lock")
	if err := os.WriteFile(target, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, filepath.Join(paths.ConfigDir, "rotation.lock")); err != nil {
		t.Fatal(err)
	}
	if code, err := Run([]string{"cab", "run"}, "test"); err == nil || code != 2 {
		t.Fatalf("expected unsafe lock rejection, code=%d err=%v", code, err)
	}
}
