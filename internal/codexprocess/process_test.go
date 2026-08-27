package codexprocess

import "testing"

func TestParsePSAcceptsOnlyLiveExactCodex(t *testing.T) {
	process, ok := parsePS(42, "7 05:12 pts/3 Sl+ /opt/codex\n")
	if !ok || process.PID != 42 || process.ParentPID != 7 || process.Elapsed != "05:12" || process.TTY != "pts/3" {
		t.Fatalf("unexpected process: %#v ok=%t", process, ok)
	}
	for _, value := range []string{
		"7 05:12 pts/3 Z+ /opt/codex\n",
		"7 05:12 pts/3 Sl+ /opt/not-codex\n",
		"invalid\n",
	} {
		if _, ok := parsePS(42, value); ok {
			t.Fatalf("accepted %q", value)
		}
	}
}
