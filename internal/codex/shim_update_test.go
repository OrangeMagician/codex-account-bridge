package codex

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

func useUpdateRegistry(t *testing.T, version string) {
	t.Helper()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, `{"version":%q}`, version)
	}))
	original := latestCodexVersionURL
	latestCodexVersionURL = server.URL
	t.Cleanup(func() { latestCodexVersionURL = original; server.Close() })
}

func TestLoggedInRecognizesOfficialStderrMissingLogin(t *testing.T) {
	path := filepath.Join(t.TempDir(), "official")
	if err := os.WriteFile(path, []byte("#!/bin/sh\nprintf 'Not logged in\\n' >&2\nexit 1\n"), 0700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("CAB_REAL_CODEX", path)
	loggedIn, err := LoggedIn(t.TempDir())
	if loggedIn || err != nil {
		t.Fatalf("loggedIn=%t err=%v", loggedIn, err)
	}
}

func TestUpdatePreservesRoutingAndResolvesNewRelease(t *testing.T) {
	for _, symlink := range []bool{true, false} {
		t.Run(fmt.Sprint(symlink), func(t *testing.T) {
			root := t.TempDir()
			public := filepath.Join(root, "codex")
			old := filepath.Join(root, "old")
			newBinary := filepath.Join(root, "new")
			self, _ := os.Executable()
			if err := os.Symlink(self, public); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(newBinary, []byte("#!/bin/sh\nprintf 'codex-cli 0.162.1\\n'\n"), 0700); err != nil {
				t.Fatal(err)
			}
			install := `ln -s "$CAB_TEST_NEW" "$CAB_TEST_ENTRY"`
			if !symlink {
				install = `cp "$CAB_TEST_NEW" "$CAB_TEST_ENTRY"`
			}
			script := "#!/bin/sh\nif [ \"$1\" = update ]; then\nrm \"$CAB_TEST_ENTRY\"\n" + install + "\nelse\nprintf 'codex-cli 0.160.0\\n'\nfi\n"
			if err := os.WriteFile(old, []byte(script), 0700); err != nil {
				t.Fatal(err)
			}
			if err := os.Symlink(old, public+".cab-backup-20260101T000000Z"); err != nil {
				t.Fatal(err)
			}
			t.Setenv("PATH", root+string(os.PathListSeparator)+"/usr/bin:/bin")
			t.Setenv("CAB_REAL_CODEX", "")
			t.Setenv("CAB_TEST_NEW", newBinary)
			t.Setenv("CAB_TEST_ENTRY", public)
			useUpdateRegistry(t, "0.162.1")
			code, err := Update()
			if err != nil || code != 0 {
				t.Fatalf("update=%d %v", code, err)
			}
			if !RemoteRoutingReady() {
				t.Fatal("updater removed routing")
			}
			real, err := FindReal("codex")
			if err != nil || real == old {
				t.Fatalf("resolved old release: %s %v", real, err)
			}
		})
	}
}

func TestUpdateRejectsSuccessfulExitWithoutVersionChange(t *testing.T) {
	path := filepath.Join(t.TempDir(), "official")
	script := "#!/bin/sh\nif [ \"$1\" = --version ]; then printf 'codex-cli 0.160.0\\n'; fi\n"
	if err := os.WriteFile(path, []byte(script), 0700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("CAB_REAL_CODEX", path)
	useUpdateRegistry(t, "0.162.1")
	if code, err := Update(); code == 0 || err == nil {
		t.Fatalf("outdated install reported success: %d %v", code, err)
	}
}

func TestRestoreUpdatedShimRecoversRemovedEntry(t *testing.T) {
	entry := filepath.Join(t.TempDir(), "codex")
	if err := restoreUpdatedShims([]string{entry}); err != nil {
		t.Fatal(err)
	}
	if !sameAsSelf(entry) {
		t.Fatal("missing entry was not restored")
	}
}
