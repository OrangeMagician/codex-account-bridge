package app

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"

	"github.com/OrangeMagician/codex-account-bridge/internal/config"
)

func TestSharedIndexRepairOnSwitchAndLaunch(t *testing.T) {
	root := t.TempDir()
	t.Setenv("CAB_CONFIG_HOME", filepath.Join(root, "config"))
	t.Setenv("CAB_DATA_HOME", filepath.Join(root, "data"))
	trueBinary, err := exec.LookPath("true")
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("CAB_REAL_CODEX", trueBinary)
	paths, err := config.DefaultPaths()
	if err != nil {
		t.Fatal(err)
	}
	cfg := config.Empty()
	cfg.DefaultAccount, cfg.RemoteAccount = "one", "one"
	cfg.SharedSessionsDir = filepath.Join(paths.DataDir, "shared", "sessions")
	for _, name := range []string{"one", "two"} {
		cfg.Accounts = append(cfg.Accounts, config.Account{Name: name, Home: filepath.Join(paths.DataDir, "accounts", name)})
	}
	python := func(script string) {
		t.Helper()
		cmd := exec.Command("/usr/bin/python3", "-I", "-c", script, paths.DataDir)
		if output, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("fixture: %v\n%s", err, output)
		}
	}
	python(`
import pathlib,sys,sqlite3,json
root=pathlib.Path(sys.argv[1]); shared=root/'shared/sessions'; shared.mkdir(parents=True)
for label,date in [('old','2026-09-04T00:00:00Z'),('new','2026-09-19T00:00:00Z')]:
 p=shared/('rollout-'+label+'-thread.jsonl')
 p.write_text(json.dumps({'timestamp':date,'type':'session_meta','payload':{'id':'thread'}})+'\n')
for name in ['one','two']:
 home=root/'accounts'/name; home.mkdir(parents=True); (home/'sessions').symlink_to(shared)
 with sqlite3.connect(home/'state_5.sqlite') as db:
  db.execute('create table threads(id text primary key,rollout_path text,updated_at integer,name text,is_pinned integer,project_id text,cwd text,title text)')
  db.execute('insert into threads values(?,?,?,?,?,?,?,?)',('thread',str(shared/('rollout-'+('new' if name=='one' else 'old')+'-thread.jsonl')),1,'Retained task' if name=='one' else '/project',1 if name=='one' else 0,None,'/project','Useful title'))
`)
	if err := config.EnsureConfigDir(paths); err != nil {
		t.Fatal(err)
	}
	if err := config.Save(paths, cfg); err != nil {
		t.Fatal(err)
	}
	for _, argv := range [][]string{
		{"cab", "remote", "use", "two"},
		{"cab", "sessions", "repair-index", "--json"},
		{"codex", "--version"},
		{"cab", "app-server", "--account", "two"},
		{"cab", "run", "--account", "two", "--", "resume", "--last"},
	} {
		python(`
import pathlib,sys,sqlite3
root=pathlib.Path(sys.argv[1])
with sqlite3.connect(root/'accounts/two/state_5.sqlite') as db:
 db.execute('update threads set rollout_path=?',(str(root/'shared/sessions/rollout-old-thread.jsonl'),))
`)
		if code, err := Run(argv, "test"); err != nil || code != 0 {
			t.Fatalf("%v: code=%d err=%v", argv, code, err)
		}
		python(`
import pathlib,sys,sqlite3
root=pathlib.Path(sys.argv[1])
with sqlite3.connect(root/'accounts/two/state_5.sqlite') as db:
 path=db.execute('select rollout_path from threads').fetchone()[0]
 assert pathlib.Path(path).resolve()==(root/'shared/sessions/rollout-new-thread.jsonl').resolve(),path
 metadata=db.execute('select name,is_pinned,project_id from threads').fetchone()
 assert metadata==('Retained task',1,None),metadata
`)
	}
	// Refuse a switch before changing the selected account if repair cannot run.
	if err := os.WriteFile(filepath.Join(cfg.Accounts[1].Home, "state_5.sqlite"), []byte("broken"), 0o600); err != nil {
		t.Fatal(err)
	}
	if code, err := Run([]string{"cab", "remote", "use", "one"}, "test"); err == nil || code == 0 {
		t.Fatal("switch succeeded with a corrupt index")
	}
	current, err := config.Load(paths)
	if err != nil || current.RemoteAccount != "two" {
		t.Fatalf("failed repair changed selected account: %q, %v", current.RemoteAccount, err)
	}
}
