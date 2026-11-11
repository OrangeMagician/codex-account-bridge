package session

import (
	"os/exec"
	"testing"

	"github.com/OrangeMagician/codex-account-bridge/internal/config"
)

func TestIndexRepairRequiresSharedSessionOptIn(t *testing.T) {
	// A disabled configuration must not inspect any account, invoke Python, or
	// create a data directory, even if its paths are inaccessible.
	report, err := RepairIndexes(config.Paths{DataDir: "/nonexistent"}, config.Config{
		Accounts: []config.Account{{Name: "one", Home: "/nonexistent"}},
	})
	if err != nil || report.Updated != 0 || len(report.Backups) != 0 {
		t.Fatalf("unexpected repair without consent: %+v, %v", report, err)
	}
}

func TestIndexRepairSQLiteRegressions(t *testing.T) {
	for _, script := range []string{"index_sync_test.py", "desktop_sync_test.py"} {
		t.Run(script, func(t *testing.T) {
			cmd := exec.Command("/usr/bin/python3", "-I", script, "-v")
			if output, err := cmd.CombinedOutput(); err != nil {
				t.Fatalf("index repair regressions: %v\n%s", err, output)
			}
		})
	}
}
