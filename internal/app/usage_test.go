package app

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestUsageJSONKeepsPerAccountFailuresIsolated(t *testing.T) {
	root := t.TempDir()
	fake := filepath.Join(root, "codex-real")
	script := `#!/bin/sh
if [ "$1" = "login" ]; then
  [ "$(basename "$CODEX_HOME")" != "missing" ]
  exit $?
fi
IFS= read -r initialize
printf '%s\n' '{"id":1,"result":{}}'
IFS= read -r initialized
IFS= read -r account
printf '%s\n' '{"id":2,"result":{"account":{"type":"chatgpt","planType":"plus"},"requiresOpenaiAuth":true}}'
IFS= read -r limits
printf '%s\n' '{"id":3,"result":{"rateLimits":{"primary":{"usedPercent":25,"windowDurationMins":300,"resetsAt":1788139274},"planType":"plus"},"rateLimitsByLimitId":null,"rateLimitResetCredits":null}}'
`
	if err := os.WriteFile(fake, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("CAB_REAL_CODEX", fake)
	t.Setenv("CAB_CONFIG_HOME", filepath.Join(root, "config"))
	t.Setenv("CAB_DATA_HOME", filepath.Join(root, "data"))
	_, _ = Run([]string{"cab", "init"}, "test")
	_, _ = Run([]string{"cab", "account", "add", "good"}, "test")
	_, _ = Run([]string{"cab", "account", "add", "missing"}, "test")

	read, write, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	original := os.Stdout
	os.Stdout = write
	code, runErr := Run([]string{"cab", "usage", "--json"}, "test")
	_ = write.Close()
	os.Stdout = original
	if runErr != nil || code != 0 {
		t.Fatalf("usage: code=%d err=%v", code, runErr)
	}
	var output bytes.Buffer
	_, _ = output.ReadFrom(read)
	var report usageOutput
	if err := json.Unmarshal(output.Bytes(), &report); err != nil {
		t.Fatalf("decode %q: %v", output.String(), err)
	}
	if len(report.Accounts) != 2 || report.Accounts[0].Usage == nil || report.Accounts[0].Usage.RateLimits.Primary == nil {
		t.Fatalf("unexpected report: %#v", report)
	}
	if report.Accounts[1].Error != "account is not logged in" {
		t.Fatalf("missing account error = %q", report.Accounts[1].Error)
	}
}
