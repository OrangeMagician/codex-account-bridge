package session

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/OrangeMagician/codex-account-bridge/internal/config"
)

func TestEnableDisableSharesActiveAndArchivedHistoryWithoutAuth(t *testing.T) {
	root := t.TempDir()
	paths := config.Paths{ConfigDir: filepath.Join(root, "config"), DataDir: filepath.Join(root, "data"), File: filepath.Join(root, "config", "config.json")}
	one := filepath.Join(root, "one")
	two := filepath.Join(root, "two")
	writeSession(t, one, "a.jsonl", "one")
	writeSession(t, two, "b.jsonl", "two")
	writeHistory(t, one, "archived_sessions", "old-a.jsonl", "old-one")
	writeHistory(t, two, "archived_sessions", "old-b.jsonl", "old-two")
	if err := os.WriteFile(filepath.Join(one, "auth.json"), []byte("secret-one"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(two, "auth.json"), []byte("secret-two"), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg := config.Empty()
	cfg.Accounts = []config.Account{{Name: "one", Home: one}, {Name: "two", Home: two}}
	if err := Enable(paths, &cfg); err != nil {
		t.Fatal(err)
	}
	for _, home := range []string{one, two} {
		for _, name := range historyDirectoryNames {
			info, err := os.Lstat(filepath.Join(home, name))
			if err != nil || info.Mode()&os.ModeSymlink == 0 {
				t.Fatalf("%s is not symlink for %s", name, home)
			}
		}
	}
	sharedArchived := filepath.Join(filepath.Dir(cfg.SharedSessionsDir), "archived_sessions")
	for name, want := range map[string]string{"old-a.jsonl": "old-one", "old-b.jsonl": "old-two"} {
		data, err := os.ReadFile(filepath.Join(sharedArchived, name))
		if err != nil || string(data) != want {
			t.Fatalf("shared archived %s = %q, %v", name, data, err)
		}
	}
	for name, want := range map[string]string{"a.jsonl": "one", "b.jsonl": "two"} {
		data, err := os.ReadFile(filepath.Join(cfg.SharedSessionsDir, name))
		if err != nil || string(data) != want {
			t.Fatalf("shared %s = %q, %v", name, data, err)
		}
	}
	if _, err := os.Stat(filepath.Join(cfg.SharedSessionsDir, "auth.json")); !os.IsNotExist(err) {
		t.Fatal("auth.json must never be shared")
	}
	if err := Disable(paths, &cfg); err != nil {
		t.Fatal(err)
	}
	for _, home := range []string{one, two} {
		for _, name := range historyDirectoryNames {
			info, err := os.Lstat(filepath.Join(home, name))
			if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
				t.Fatalf("%s was not restored for %s", name, home)
			}
		}
	}
}

func TestEnableUpgradesLegacySharingWithArchivedHistory(t *testing.T) {
	root := t.TempDir()
	paths := config.Paths{DataDir: filepath.Join(root, "data")}
	one := filepath.Join(root, "one")
	two := filepath.Join(root, "two")
	sharedSessions := filepath.Join(paths.DataDir, "shared", "sessions")
	if err := os.MkdirAll(sharedSessions, 0o700); err != nil {
		t.Fatal(err)
	}
	for _, home := range []string{one, two} {
		if err := os.MkdirAll(home, 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(sharedSessions, filepath.Join(home, "sessions")); err != nil {
			t.Fatal(err)
		}
	}
	writeHistory(t, one, "archived_sessions", "one.jsonl", "one")
	writeHistory(t, two, "archived_sessions", "two.jsonl", "two")
	cfg := config.Empty()
	cfg.SharedSessionsDir = sharedSessions
	cfg.Accounts = []config.Account{{Name: "one", Home: one}, {Name: "two", Home: two}}

	if err := Enable(paths, &cfg); err != nil {
		t.Fatal(err)
	}
	for _, home := range []string{one, two} {
		info, err := os.Lstat(filepath.Join(home, "archived_sessions"))
		if err != nil || info.Mode()&os.ModeSymlink == 0 {
			t.Fatalf("archived history was not upgraded for %s", home)
		}
	}
}

func TestEnableRefusesConflictingSessionsWithoutMutation(t *testing.T) {
	root := t.TempDir()
	paths := config.Paths{DataDir: filepath.Join(root, "data")}
	one := filepath.Join(root, "one")
	two := filepath.Join(root, "two")
	writeSession(t, one, "same.jsonl", "one")
	writeSession(t, two, "same.jsonl", "two")
	cfg := config.Empty()
	cfg.Accounts = []config.Account{{Name: "one", Home: one}, {Name: "two", Home: two}}
	if err := Enable(paths, &cfg); err == nil {
		t.Fatal("expected collision")
	}
	for _, home := range []string{one, two} {
		info, err := os.Lstat(filepath.Join(home, "sessions"))
		if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
			t.Fatalf("source mutated after collision: %s", home)
		}
	}
}

func TestEnableRejectsNestedSymlink(t *testing.T) {
	root := t.TempDir()
	one := filepath.Join(root, "one")
	two := filepath.Join(root, "two")
	writeSession(t, one, "a.jsonl", "one")
	if err := os.MkdirAll(filepath.Join(two, "sessions"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(one, "sessions", "a.jsonl"), filepath.Join(two, "sessions", "leak.jsonl")); err != nil {
		t.Fatal(err)
	}
	cfg := config.Empty()
	cfg.Accounts = []config.Account{{Name: "one", Home: one}, {Name: "two", Home: two}}
	if err := Enable(config.Paths{DataDir: filepath.Join(root, "data")}, &cfg); err == nil {
		t.Fatal("expected nested symlink rejection")
	}
}

func writeSession(t *testing.T, home, name, value string) {
	t.Helper()
	writeHistory(t, home, "sessions", name, value)
}

func writeHistory(t *testing.T, home, directory, name, value string) {
	t.Helper()
	dir := filepath.Join(home, directory)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, name), []byte(value), 0o600); err != nil {
		t.Fatal(err)
	}
}
