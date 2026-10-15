package codex

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestFreshRemoteConnectionChecksActualHomeAndAccountWithoutLeakingIdentity(t *testing.T) {
	for _, test := range []struct {
		name, home, account string
		success             bool
	}{
		{"correct", "/accounts/selected", `{"type":"chatgpt","email":"private@example.test"}`, true},
		{"wrong-home", "/accounts/old", `{"type":"chatgpt"}`, false},
		{"missing-home", "", `{"type":"chatgpt"}`, false},
		{"logged-out", "/accounts/selected", `null`, false},
		{"api-key", "/accounts/selected", `{"type":"apiKey"}`, false},
	} {
		t.Run(test.name, func(t *testing.T) {
			root := t.TempDir()
			binary := filepath.Join(root, "codex")
			script := `#!/bin/sh
IFS= read -r initialize
printf '{"id":1,"result":{"codexHome":"%s"}}\n' "$CAB_TEST_HOME"
IFS= read -r initialized
IFS= read -r account
printf '{"id":2,"result":{"account":%s}}\n' "$CAB_TEST_ACCOUNT"
`
			if err := os.WriteFile(binary, []byte(script), 0700); err != nil {
				t.Fatal(err)
			}
			t.Setenv("CAB_TEST_HOME", test.home)
			t.Setenv("CAB_TEST_ACCOUNT", test.account)
			ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
			defer cancel()
			err := verifyRemoteCommand(exec.CommandContext(ctx, binary, "app-server"), "/accounts/selected")
			if (err == nil) != test.success {
				t.Fatalf("success=%v err=%v", test.success, err)
			}
			if err != nil && strings.Contains(err.Error(), "private@example.test") {
				t.Fatal("account identity leaked")
			}
		})
	}
}
