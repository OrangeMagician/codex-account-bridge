package codex

import (
	_ "embed"
	"math"
	"os/exec"
	"path/filepath"
	"testing"
)

func TestTokenEventReader(t *testing.T) {
	python, err := findPython3()
	if err != nil {
		t.Skip(err)
	}
	cmd := exec.Command(python, "-m", "unittest", "-v", "token_reader_test.py")
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("usage regressions: %v\n%s", err, out)
	}
}

// Include Python regressions in Go's test cache fingerprint.
//
//go:embed token_reader_test.py
var tokenReaderRegressionSource string

func TestReadTokenUsageIncludesCostAndReusesCache(t *testing.T) {
	python, err := findPython3()
	if err != nil {
		t.Skip(err)
	}
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("CAB_DATA_HOME", filepath.Join(root, "cache"))
	t.Setenv("CAB_CONFIG_HOME", filepath.Join(root, "config"))
	home := filepath.Join(root, "account")
	script := `import json, sqlite3, sys
from pathlib import Path
home=Path(sys.argv[1]); (home/'sessions').mkdir(parents=True)
p=home/'sessions/rollout-test.jsonl'
events=[{"type":"session_meta","payload":{"id":"test"}},
{"type":"turn_context","payload":{"model":"gpt-6-sol"}},
{"timestamp":"2026-09-24T12:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000000,"cached_input_tokens":800000,"output_tokens":100000,"total_tokens":1100000}}}}]
p.write_text(''.join(json.dumps(e)+'\n' for e in events))
with sqlite3.connect(home/'state_5.sqlite') as db:
 db.execute('create table threads(id text,rollout_path text)')
 db.execute('insert into threads values(?,?)',('test',str(p)))
`
	if out, err := exec.Command(python, "-c", script, home).CombinedOutput(); err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	report, err := ReadTokenUsage([]string{home})
	if err != nil {
		t.Fatal(err)
	}
	if report.CostEstimate == nil || math.Abs(report.CostEstimate.Total.USD-1.56) > 1e-9 || report.CostEstimate.Total.PricedTokens != report.TotalTokens {
		t.Fatalf("bad estimate: %+v", report)
	}
	cached, err := ReadTokenUsage([]string{home})
	if err != nil || cached.ScannedBytes != 0 || cached.CostEstimate.Total != report.CostEstimate.Total {
		t.Fatalf("cache changed estimate: %+v, %v", cached, err)
	}
	empty, err := ReadTokenUsage(nil)
	if err != nil || empty.CostEstimate == nil || empty.CostEstimate.Total.USD != 0 {
		t.Fatalf("empty report: %+v %v", empty, err)
	}
}
