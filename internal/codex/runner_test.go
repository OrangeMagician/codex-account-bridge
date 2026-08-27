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

func TestFindRealUsesRecoverableShimBackup(t *testing.T) {
	dir := t.TempDir()
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(self, filepath.Join(dir, "codex")); err != nil {
		t.Fatal(err)
	}
	backup := filepath.Join(dir, "codex.cab-backup-20260827T051837Z")
	if err := os.WriteFile(backup, []byte("#!/bin/sh\nexit 0\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("CAB_REAL_CODEX", "")
	t.Setenv("PATH", dir)
	got, err := FindReal("codex")
	if err != nil {
		t.Fatal(err)
	}
	if got != backup {
		t.Fatalf("FindReal() = %q, want %q", got, backup)
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

func TestRunBrowserLoginUsesOfficialAppServerFlow(t *testing.T) {
	root := t.TempDir()
	fake := filepath.Join(root, "codex-real")
	output := filepath.Join(root, "output")
	script := `#!/bin/sh
printf '%s\n' "$CODEX_HOME" > "$CAB_TEST_OUTPUT"
printf '%s\n' "$@" >> "$CAB_TEST_OUTPUT"
IFS= read -r initialize
printf '%s\n' '{"id":1,"result":{"userAgent":"test","codexHome":"/tmp/test"}}'
IFS= read -r initialized
IFS= read -r login
printf '%s\n' '{"id":2,"result":{"type":"chatgpt","loginId":"login-1","authUrl":"https://auth.openai.com/oauth/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback"}}'
printf '%s\n' '{"method":"account/login/completed","params":{"loginId":"login-1","success":true,"error":null}}'
`
	if err := os.WriteFile(fake, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("CAB_REAL_CODEX", fake)
	t.Setenv("CAB_TEST_OUTPUT", output)
	home := filepath.Join(root, "account")
	code, err := RunBrowserLogin(home)
	if err != nil || code != 0 {
		t.Fatalf("code=%d err=%v", code, err)
	}
	data, err := os.ReadFile(output)
	if err != nil {
		t.Fatal(err)
	}
	want := home + "\napp-server\n"
	if string(data) != want {
		t.Fatalf("output = %q, want %q", data, want)
	}
}

func TestValidateBrowserAuthURLRejectsUntrustedTargets(t *testing.T) {
	valid := "https://auth.openai.com/oauth/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback"
	if err := validateBrowserAuthURL(valid); err != nil {
		t.Fatalf("valid URL rejected: %v", err)
	}
	for _, candidate := range []string{
		"https://example.com/oauth/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback",
		"https://auth.openai.com/oauth/authorize?redirect_uri=https%3A%2F%2Fevil.example%2Fauth%2Fcallback",
		"https://auth.openai.com/oauth/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fwrong",
	} {
		if err := validateBrowserAuthURL(candidate); err == nil {
			t.Fatalf("untrusted URL accepted: %s", candidate)
		}
	}
}
