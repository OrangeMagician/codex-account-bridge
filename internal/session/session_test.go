package session

import (
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/OrangeMagician/codex-account-bridge/internal/config"
)

func TestImportLegacyMergesDefaultHistoryWithoutRemovingSource(t *testing.T) {
	root := t.TempDir()
	paths := config.Paths{ConfigDir: filepath.Join(root, "config"), DataDir: filepath.Join(root, "data"), File: filepath.Join(root, "config", "config.json")}
	source := filepath.Join(root, "legacy")
	legacyFile := filepath.Join(source, "sessions", "2026", "08", "27", "rollout.jsonl")
	if err := os.MkdirAll(filepath.Dir(legacyFile), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(legacyFile, []byte("legacy"), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg := config.Empty()
	cfg.SharedSessionsDir = filepath.Join(paths.DataDir, "shared", "sessions")
	report, err := ImportLegacy(paths, cfg, source)
	if err != nil {
		t.Fatal(err)
	}
	if report.Sessions != 1 {
		t.Fatalf("sessions=%d", report.Sessions)
	}
	if _, err := os.Stat(legacyFile); err != nil {
		t.Fatalf("source removed: %v", err)
	}
	if _, err := os.Stat(filepath.Join(cfg.SharedSessionsDir, "2026", "08", "27", "rollout.jsonl")); err != nil {
		t.Fatalf("shared copy missing: %v", err)
	}
	remaining, err := LegacyStatus(cfg, source)
	if err != nil {
		t.Fatal(err)
	}
	if remaining.Sessions != 0 {
		t.Fatalf("remaining sessions=%d", remaining.Sessions)
	}
}

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

func TestConfigSaveFailureRollsBackSessionEnable(t *testing.T) {
	root := t.TempDir()
	paths := config.Paths{ConfigDir: filepath.Join(root, "config"), DataDir: filepath.Join(root, "data")}
	paths.File = filepath.Join(paths.ConfigDir, "config.json")
	one := filepath.Join(paths.DataDir, "accounts", "one")
	two := filepath.Join(paths.DataDir, "accounts", "two")
	for _, home := range []string{one, two} {
		if err := os.MkdirAll(filepath.Join(home, "sessions"), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	cfg := config.Empty()
	cfg.Accounts = []config.Account{{Name: "one", Home: one}, {Name: "two", Home: two}}
	cfg.DefaultAccount = "one"
	if err := config.Save(paths, cfg); err != nil {
		t.Fatal(err)
	}

	_, err := config.Update(paths, func(latest *config.Config) (config.Mutation, error) {
		mutation, err := PrepareEnable(paths, latest)
		if err != nil {
			return config.Mutation{}, err
		}
		saved := paths.File + ".test-saved"
		if err := os.Rename(paths.File, saved); err != nil {
			_ = mutation.Rollback()
			return config.Mutation{}, err
		}
		if err := os.Symlink(saved, paths.File); err != nil {
			_ = os.Rename(saved, paths.File)
			_ = mutation.Rollback()
			return config.Mutation{}, err
		}
		return config.Mutation{
			Rollback: func() error {
				removeErr := os.Remove(paths.File)
				restoreErr := os.Rename(saved, paths.File)
				return errors.Join(removeErr, restoreErr, mutation.Rollback())
			},
			Commit: mutation.Commit,
		}, nil
	})
	if err == nil {
		t.Fatal("expected configuration save failure")
	}
	loaded, loadErr := config.Load(paths)
	if loadErr != nil {
		t.Fatal(loadErr)
	}
	if loaded.SharedSessionsDir != "" {
		t.Fatalf("shared sessions persisted after rollback: %s", loaded.SharedSessionsDir)
	}
	for _, home := range []string{one, two} {
		info, statErr := os.Lstat(filepath.Join(home, "sessions"))
		if statErr != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
			t.Fatalf("session directory was not restored for %s: info=%v err=%v", home, info, statErr)
		}
	}
	if _, statErr := os.Lstat(journalPath(paths)); !errors.Is(statErr, os.ErrNotExist) {
		t.Fatalf("session journal remains after rollback: %v", statErr)
	}
}

func TestSecureDirRejectsFinalSymlink(t *testing.T) {
	root := t.TempDir()
	target := filepath.Join(root, "target")
	link := filepath.Join(root, "shared")
	if err := os.Mkdir(target, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}
	if err := secureDir(link); err == nil {
		t.Fatal("expected symlink directory rejection")
	}
}

func TestRecoverRollsBackInterruptedEnableBeforeConfigSave(t *testing.T) {
	root := t.TempDir()
	paths := config.Paths{DataDir: filepath.Join(root, "data")}
	home := filepath.Join(root, "one")
	target := filepath.Join(home, "sessions")
	shared := filepath.Join(paths.DataDir, "shared", "sessions")
	backup := target + ".cab-backup-test"
	if err := os.MkdirAll(target, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(shared, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(target, backup); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(shared, target); err != nil {
		t.Fatal(err)
	}
	cfg := config.Empty()
	cfg.Accounts = []config.Account{{Name: "one", Home: home}}
	journal := operationJournal{Version: 1, Operation: "enable", Shared: shared, Items: []operationTarget{{Target: target, Shared: shared, Backup: backup}}}
	if err := writeJournal(paths, journal); err != nil {
		t.Fatal(err)
	}

	if err := Recover(paths, cfg); err != nil {
		t.Fatal(err)
	}
	info, err := os.Lstat(target)
	if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		t.Fatalf("original sessions directory was not restored: info=%v err=%v", info, err)
	}
	if _, err := os.Lstat(backup); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("backup remains after recovery: %v", err)
	}
	if _, err := os.Lstat(journalPath(paths)); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("journal remains after recovery: %v", err)
	}
}

func TestRecoverRollsBackInterruptedDisableBeforeConfigSave(t *testing.T) {
	root := t.TempDir()
	paths := config.Paths{DataDir: filepath.Join(root, "data")}
	home := filepath.Join(root, "one")
	target := filepath.Join(home, "sessions")
	shared := filepath.Join(paths.DataDir, "shared", "sessions")
	stage := filepath.Join(home, ".cab-sessions-disable-test")
	if err := os.MkdirAll(shared, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(target, 0o700); err != nil {
		t.Fatal(err)
	}
	cfg := config.Empty()
	cfg.SharedSessionsDir = shared
	cfg.Accounts = []config.Account{{Name: "one", Home: home}}
	journal := operationJournal{Version: 1, Operation: "disable", Shared: shared, Items: []operationTarget{{Target: target, Shared: shared, Stage: stage}}}
	if err := writeJournal(paths, journal); err != nil {
		t.Fatal(err)
	}

	if err := Recover(paths, cfg); err != nil {
		t.Fatal(err)
	}
	info, err := os.Lstat(target)
	if err != nil || info.Mode()&os.ModeSymlink == 0 || !sameResolvedPath(target, shared) {
		t.Fatalf("shared sessions link was not restored: info=%v err=%v", info, err)
	}
	if _, err := os.Lstat(journalPath(paths)); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("journal remains after recovery: %v", err)
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
