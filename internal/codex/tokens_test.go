package codex

import (
	_ "embed"
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

// Include Python regressions in Go's test cache fingerprint.
//
//go:embed token_reader_test.py
var tokenReaderRegressionSource string
