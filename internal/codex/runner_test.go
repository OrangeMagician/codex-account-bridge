package codex

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRunPassesArgsWithoutShellAndSetsHome(t *testing.T) {
	root := t.TempDir()
	fake := filepath.Join(root, "codex-real")
	output := filepath.Join(root, "output")
	script := "#!/bin/sh\nprintf '%s\\n' \"$CODEX_HOME\" > \"$CAB_TEST_OUTPUT\"\nprintf '%s\\n' \"$@\" >> \"$CAB_TEST_OUTPUT\"\nexit 7\n"
	if err := os.WriteFile(fake, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("CAB_REAL_CODEX", fake)
	t.Setenv("CAB_TEST_OUTPUT", output)
	t.Setenv("CODEX_THREAD_ID", "must-not-leak")
	home := filepath.Join(root, "account")
	code, err := Run(home, []string{"exec", "literal;$(touch nope)"})
	if err != nil {
		t.Fatal(err)
	}
	if code != 7 {
		t.Fatalf("exit code = %d", code)
	}
	data, err := os.ReadFile(output)
	if err != nil {
		t.Fatal(err)
	}
	want := home + "\nexec\nliteral;$(touch nope)\n"
	if string(data) != want {
		t.Fatalf("output = %q, want %q", data, want)
	}
	if strings.Contains(string(data), "must-not-leak") {
		t.Fatal("thread id leaked")
	}
}

func TestFindRealRejectsSelfOverride(t *testing.T) {
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("CAB_REAL_CODEX", self)
	if _, err := FindReal("codex"); err == nil {
		t.Fatal("expected self-recursion rejection")
	}
}

func TestLoggedInUsesOfficialStatusWithoutReadingCredentials(t *testing.T) {
	root := t.TempDir()
	fake := filepath.Join(root, "codex-real")
	output := filepath.Join(root, "output")
	script := "#!/bin/sh\nprintf '%s\\n' \"$CODEX_HOME\" > \"$CAB_TEST_OUTPUT\"\nprintf '%s\\n' \"$@\" >> \"$CAB_TEST_OUTPUT\"\nexit 0\n"
	if err := os.WriteFile(fake, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("CAB_REAL_CODEX", fake)
	t.Setenv("CAB_TEST_OUTPUT", output)
	home := filepath.Join(root, "existing")
	loggedIn, err := LoggedIn(home)
	if err != nil || !loggedIn {
		t.Fatalf("loggedIn=%t err=%v", loggedIn, err)
	}
	data, err := os.ReadFile(output)
	if err != nil {
		t.Fatal(err)
	}
	want := home + "\nlogin\nstatus\n"
	if string(data) != want {
		t.Fatalf("output = %q, want %q", data, want)
	}
}
