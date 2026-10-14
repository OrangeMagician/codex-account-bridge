package codex

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestProbeFailureReportsCategoryWithoutRawOutputOrRetry(t *testing.T) {
	for _, test := range []struct{ output, reason string }{
		{"401 Unauthorized secret-token", "authentication_required"},
		{"model is not available secret-token", "model_unavailable"},
		{"usage limit reached secret-token", "rate_limited"},
		{"network connection failed secret-token", "network_failed"},
		{"unexpected secret-token", "official_command_failed"},
	} {
		t.Run(test.reason, func(t *testing.T) {
			root := t.TempDir()
			binary := filepath.Join(root, "official")
			calls := filepath.Join(root, "calls")
			script := "#!/bin/sh\nprintf x >> \"$CAB_TEST_CALLS\"\nprintf '%s' \"$CAB_TEST_ERROR\" >&2\nexit 1\n"
			if err := os.WriteFile(binary, []byte(script), 0700); err != nil {
				t.Fatal(err)
			}
			t.Setenv("CAB_REAL_CODEX", binary)
			t.Setenv("CAB_TEST_CALLS", calls)
			t.Setenv("CAB_TEST_ERROR", test.output)
			err := ProbeUsage(root, DefaultUsageProbeModel)
			if err == nil || !strings.Contains(err.Error(), test.reason) || strings.Contains(err.Error(), "secret-token") {
				t.Fatalf("unsafe or missing diagnostic: %v", err)
			}
			data, _ := os.ReadFile(calls)
			if string(data) != "x" {
				t.Fatalf("probe retried: %q", data)
			}
		})
	}
}
