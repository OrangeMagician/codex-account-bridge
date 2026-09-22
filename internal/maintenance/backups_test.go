package maintenance

import (
	"bufio"
	"github.com/OrangeMagician/codex-account-bridge/internal/config"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

func fixture(t *testing.T) (config.Paths, config.Config, string) {
	t.Helper()
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	home := filepath.Join(root, "account")
	data := filepath.Join(root, "data")
	for _, p := range []string{home, data} {
		if err := os.Mkdir(p, 0700); err != nil {
			t.Fatal(err)
		}
	}
	return config.Paths{DataDir: data}, config.Config{Accounts: []config.Account{{Name: "work", Home: home}}}, home
}
func write(t *testing.T, path, text string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(text), 0600); err != nil {
		t.Fatal(err)
	}
}

func TestRestorePreservesCurrentVersionAndDeleteIsScoped(t *testing.T) {
	paths, cfg, home := fixture(t)
	target := filepath.Join(home, "AGENTS.md")
	backup := target + ".cab-backup-1"
	write(t, target, "current")
	write(t, backup, "earlier")
	// An unrelated sibling is never selected by the backup catalogue.
	write(t, filepath.Join(home, "unrelated.txt"), "untouched")
	items, err := List(paths, cfg)
	if err != nil || len(items) != 1 {
		t.Fatalf("list: %+v %v", items, err)
	}
	plan, err := Plan(paths, cfg, items[0].ID, "restore")
	if err != nil || !plan.Allowed {
		t.Fatalf("plan: %+v %v", plan, err)
	}
	rollback, err := Apply(plan)
	if err != nil {
		t.Fatal(err)
	}
	data, _ := os.ReadFile(target)
	prior, _ := os.ReadFile(rollback)
	if string(data) != "earlier" || string(prior) != "current" {
		t.Fatal("restore did not preserve the original")
	}
	plan, err = Plan(paths, cfg, items[0].ID, "delete")
	if err != nil {
		t.Fatal(err)
	}
	if _, err = Apply(plan); err != nil {
		t.Fatal(err)
	}
	if _, err = os.Stat(backup); !os.IsNotExist(err) {
		t.Fatal("backup not deleted")
	}
	if _, err = os.Stat(target); err != nil {
		t.Fatal("live target was touched")
	}
}

func TestUnsafeTreesAndStaleIDsFailClosed(t *testing.T) {
	paths, cfg, home := fixture(t)
	backup := filepath.Join(home, "skills.cab-backup-1")
	if err := os.Mkdir(backup, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("/nonexistent", filepath.Join(backup, "link")); err != nil {
		t.Fatal(err)
	}
	items, _ := List(paths, cfg)
	if len(items) != 1 || items[0].Safe {
		t.Fatal("unsafe tree accepted")
	}
	plan, _ := Plan(paths, cfg, items[0].ID, "delete")
	if plan.Allowed {
		t.Fatal("unsafe deletion accepted")
	}
	// A forbidden name is rejected by metadata; no credential contents are created or read.
	if err := os.Mkdir(filepath.Join(backup, "auth.json"), 0700); err != nil {
		t.Fatal(err)
	}
	if _, err := inspectTree(backup); err == nil {
		t.Fatal("credential name accepted")
	}
	file := filepath.Join(home, "AGENTS.md.cab-backup-2")
	write(t, file, "old")
	items, _ = List(paths, cfg)
	var id string
	for _, item := range items {
		if item.Path == file {
			id = item.ID
		}
	}
	write(t, file, "changed version")
	if _, err := Plan(paths, cfg, id, "restore"); err == nil {
		t.Fatal("stale ID accepted")
	}
}

func TestSharedHistoryCannotBeRestoredOverSymlink(t *testing.T) {
	paths, cfg, home := fixture(t)
	cfg.SharedSessionsDir = filepath.Join(paths.DataDir, "shared")
	if err := os.Mkdir(cfg.SharedSessionsDir, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(cfg.SharedSessionsDir, filepath.Join(home, "sessions")); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(home, "sessions.cab-backup-1"), 0700); err != nil {
		t.Fatal(err)
	}
	items, _ := List(paths, cfg)
	plan, err := Plan(paths, cfg, items[0].ID, "restore")
	if err != nil || plan.Allowed {
		t.Fatalf("shared restore: %+v %v", plan, err)
	}
}

func TestSQLiteRestoreIncludesCurrentWALInRollback(t *testing.T) {
	paths, cfg, home := fixture(t)
	target := filepath.Join(home, "state_5.sqlite")
	source := target + ".cab-backup-1"
	// SQLite helpers do not touch any credential path.
	create := `import sqlite3,sys
for p,v in [(sys.argv[1],1),(sys.argv[2],2)]:
 c=sqlite3.connect(p);c.execute('create table test(value integer)');c.execute('insert into test values(?)',(v,));c.commit();c.close()`
	if out, err := runPython(create, source, target); err != nil {
		t.Fatalf("fixture: %v %s", err, out)
	}
	writer := exec.Command("/usr/bin/python3", "-I", "-c", `import sqlite3,sys
c=sqlite3.connect(sys.argv[1]);c.execute('PRAGMA journal_mode=WAL');c.execute('PRAGMA wal_autocheckpoint=0');c.execute('insert into test values(3)');c.commit();print('ready',flush=True);sys.stdin.read();c.close()`, target)
	stdout, err := writer.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	stdin, err := writer.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := writer.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { stdin.Close(); writer.Wait() }()
	if ready, err := bufio.NewReader(stdout).ReadString('\n'); err != nil || ready != "ready\n" {
		t.Fatalf("WAL writer: %q %v", ready, err)
	}
	if info, err := os.Stat(target + "-wal"); err != nil || info.Size() == 0 {
		t.Fatal("test requires a live WAL")
	}
	items, _ := List(paths, cfg)
	plan, err := Plan(paths, cfg, items[0].ID, "restore")
	if err != nil || !plan.Allowed {
		t.Fatalf("plan %+v %v", plan, err)
	}
	rollback, err := Apply(plan)
	if err != nil {
		t.Fatal(err)
	}
	verify := `import sqlite3,sys
assert sqlite3.connect(sys.argv[1]).execute('select value from test').fetchone()[0]==1
assert sqlite3.connect(sys.argv[2]).execute('select value from test order by value').fetchall()==[(2,),(3,)]`
	if out, err := runPython(verify, target, rollback); err != nil {
		t.Fatalf("verify: %v %s", err, out)
	}
}

func runPython(script string, args ...string) ([]byte, error) {
	return exec.Command("/usr/bin/python3", append([]string{"-I", "-c", script}, args...)...).CombinedOutput()
}
