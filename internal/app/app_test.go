package app

import (
	"os"
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
