package codex

import (
	"os/exec"
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
