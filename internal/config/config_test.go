package config

import (
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"sync"
	"testing"
)

func TestSaveLoadSecurePermissions(t *testing.T) {
	root := t.TempDir()
	paths := Paths{ConfigDir: filepath.Join(root, "config"), DataDir: filepath.Join(root, "data")}
	paths.File = filepath.Join(paths.ConfigDir, "config.json")
	cfg := Empty()
	cfg.Accounts = []Account{{Name: "work", Home: filepath.Join(root, "work")}}
	cfg.DefaultAccount = "work"
	if err := Save(paths, cfg); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(paths.File)
	if err != nil {
		t.Fatal(err)
	}
	if got := info.Mode().Perm(); got != 0o600 {
		t.Fatalf("config mode = %04o, want 0600", got)
	}
	loaded, err := Load(paths)
	if err != nil {
		t.Fatal(err)
	}
	if loaded.DefaultAccount != "work" {
		t.Fatalf("default account = %q", loaded.DefaultAccount)
	}
	loaded.RemoteAccount = "work"
	if err := Save(paths, loaded); err != nil {
		t.Fatal(err)
	}
	backup, err := Load(Paths{ConfigDir: paths.ConfigDir, DataDir: paths.DataDir, File: paths.File + ".backup"})
	if err != nil {
		t.Fatal(err)
	}
	if backup.RemoteAccount != "" {
		t.Fatal("backup did not preserve the previous config")
	}
}

func TestLoadRejectsSymlink(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("symlink semantics differ")
	}
	root := t.TempDir()
	target := filepath.Join(root, "target")
	if err := os.WriteFile(target, []byte(`{"version":1,"accounts":[]}`), 0o600); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(root, "config.json")
	if err := os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}
	_, err := Load(Paths{ConfigDir: root, DataDir: filepath.Join(root, "data"), File: link})
	if err == nil {
		t.Fatal("expected symlink rejection")
	}
}

func TestLoadRejectsSymlinkAccountHome(t *testing.T) {
	root := t.TempDir()
	paths := Paths{ConfigDir: filepath.Join(root, "config"), DataDir: filepath.Join(root, "data")}
	paths.File = filepath.Join(paths.ConfigDir, "config.json")
	realHome := filepath.Join(root, "real-home")
	linkHome := filepath.Join(root, "linked-home")
	if err := os.MkdirAll(realHome, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(realHome, linkHome); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(paths.ConfigDir, 0o700); err != nil {
		t.Fatal(err)
	}
	data := fmt.Sprintf("{\"version\":1,\"default_account\":\"one\",\"accounts\":[{\"name\":\"one\",\"home\":%q}]}\n", linkHome)
	if err := os.WriteFile(paths.File, []byte(data), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := Load(paths); err == nil {
		t.Fatal("expected symlink account home rejection")
	}
}

func TestLoadRejectsUnknownAndDuplicateFields(t *testing.T) {
	root := t.TempDir()
	paths := Paths{ConfigDir: filepath.Join(root, "config"), DataDir: filepath.Join(root, "data")}
	paths.File = filepath.Join(paths.ConfigDir, "config.json")
	if err := os.MkdirAll(paths.ConfigDir, 0o700); err != nil {
		t.Fatal(err)
	}
	for _, data := range []string{
		`{"version":1,"accounts":[],"unexpected":true}`,
		`{"version":1,"version":1,"accounts":[]}`,
	} {
		if err := os.WriteFile(paths.File, []byte(data), 0o600); err != nil {
			t.Fatal(err)
		}
		if _, err := Load(paths); err == nil {
			t.Fatalf("expected invalid config rejection for %s", data)
		}
	}
}

func TestDefaultPathsRejectsFilesystemRoot(t *testing.T) {
	t.Setenv("CAB_CONFIG_HOME", string(filepath.Separator))
	t.Setenv("CAB_DATA_HOME", filepath.Join(t.TempDir(), "data"))
	if _, err := DefaultPaths(); err == nil {
		t.Fatal("expected filesystem root rejection")
	}
}

func TestConcurrentUpdatesDoNotLoseAccounts(t *testing.T) {
	root := t.TempDir()
	paths := Paths{ConfigDir: filepath.Join(root, "config"), DataDir: filepath.Join(root, "data")}
	paths.File = filepath.Join(paths.ConfigDir, "config.json")
	if _, err := UpdateSimple(paths, func(*Config) error { return nil }); err != nil {
		t.Fatal(err)
	}
	const count = 32
	errorsFound := make(chan error, count)
	var wait sync.WaitGroup
	for index := 0; index < count; index++ {
		index := index
		wait.Add(1)
		go func() {
			defer wait.Done()
			_, err := UpdateSimple(paths, func(cfg *Config) error {
				return cfg.Add(Account{Name: fmt.Sprintf("account-%02d", index), Home: filepath.Join(root, "accounts", fmt.Sprintf("%02d", index))})
			})
			errorsFound <- err
		}()
	}
	wait.Wait()
	close(errorsFound)
	for err := range errorsFound {
		if err != nil {
			t.Fatal(err)
		}
	}
	loaded, err := Load(paths)
	if err != nil {
		t.Fatal(err)
	}
	if len(loaded.Accounts) != count {
		t.Fatalf("account count = %d, want %d", len(loaded.Accounts), count)
	}
}

func TestValidateRejectsDuplicateHomes(t *testing.T) {
	root := t.TempDir()
	cfg := Empty()
	cfg.Accounts = []Account{{Name: "one", Home: root}, {Name: "two", Home: root}}
	if err := cfg.Validate(); err == nil {
		t.Fatal("expected duplicate home rejection")
	}
}

func TestRotationRoundRobinAndValidation(t *testing.T) {
	root := t.TempDir()
	cfg := Empty()
	cfg.Accounts = []Account{
		{Name: "one", Home: filepath.Join(root, "one")},
		{Name: "two", Home: filepath.Join(root, "two")},
	}
	if err := cfg.SetRotationAccounts([]string{"two", "one"}); err != nil {
		t.Fatal(err)
	}
	cfg.Rotation.Enabled = true
	first, err := cfg.NextRotationAccount()
	if err != nil || first.Name != "two" {
		t.Fatalf("first rotation = %q, err=%v", first.Name, err)
	}
	second, err := cfg.NextRotationAccount()
	if err != nil || second.Name != "one" {
		t.Fatalf("second rotation = %q, err=%v", second.Name, err)
	}
	third, err := cfg.NextRotationAccount()
	if err != nil || third.Name != "two" {
		t.Fatalf("wrapped rotation = %q, err=%v", third.Name, err)
	}
	if err := cfg.SetRotationAccounts([]string{"one", "missing"}); err == nil {
		t.Fatal("expected unknown rotation account rejection")
	}
}

func TestRemovingRotationAccountDisablesUnsafeRotation(t *testing.T) {
	root := t.TempDir()
	cfg := Empty()
	cfg.Accounts = []Account{
		{Name: "one", Home: filepath.Join(root, "one")},
		{Name: "two", Home: filepath.Join(root, "two")},
	}
	if err := cfg.SetRotationAccounts([]string{"one", "two"}); err != nil {
		t.Fatal(err)
	}
	cfg.Rotation.Enabled = true
	cfg.Rotation.NextIndex = 1
	cfg.Remove("two")
	if cfg.Rotation.Enabled {
		t.Fatal("rotation should be disabled with fewer than two accounts")
	}
	if cfg.Rotation.NextIndex != 0 {
		t.Fatalf("next index = %d, want 0", cfg.Rotation.NextIndex)
	}
	if err := cfg.Validate(); err != nil {
		t.Fatal(err)
	}
}
