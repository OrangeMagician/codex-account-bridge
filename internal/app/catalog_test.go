package app

import (
	"github.com/OrangeMagician/codex-account-bridge/internal/config"
	"os"
	"path/filepath"
	"testing"
)

func TestPresetWithoutExplicitAccountDoesNotAdvanceRotation(t *testing.T) {
	root := t.TempDir()
	t.Setenv("CAB_CONFIG_HOME", filepath.Join(root, "config"))
	t.Setenv("CAB_DATA_HOME", filepath.Join(root, "data"))
	for _, args := range [][]string{{"init"}, {"account", "add", "one"}, {"account", "add", "two"}, {"rotation", "configure", "--accounts", "one,two"}, {"rotation", "enable"}} {
		if _, err := Run(append([]string{"cab"}, args...), "test"); err != nil {
			t.Fatal(err)
		}
	}
	if code, err := Run([]string{"cab", "run", "--model", "gpt-6.1-sol"}, "test"); code != 2 || err == nil {
		t.Fatal(code, err)
	}
	paths, _ := config.DefaultPaths()
	cfg, err := config.Load(paths)
	if err != nil || cfg.Rotation.NextIndex != 0 {
		t.Fatal(cfg.Rotation, err)
	}
	for _, args := range [][]string{{"models", "--json"}, {"tasks", "list", "--json"}, {"worktrees", "list", "--json"}} {
		if code, err := Run(append([]string{"cab"}, args...), "test"); code != 2 || err == nil {
			t.Fatal(code, err)
		}
	}
	// No authentication storage is needed for argument validation.
	if _, err = os.Stat(filepath.Join(root, "missing")); !os.IsNotExist(err) {
		t.Fatal(err)
	}
}
