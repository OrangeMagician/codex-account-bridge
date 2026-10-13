package app

import (
	"github.com/OrangeMagician/codex-account-bridge/internal/config"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRemoteSelectionRejectsLoggedOutAccountWithoutChangingSelection(t *testing.T) {
	root := t.TempDir()
	official := filepath.Join(root, "official")
	if err := os.WriteFile(official, []byte("#!/bin/sh\nprintf 'Not logged in\\n' >&2\nexit 1\n"), 0700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("CAB_REAL_CODEX", official)
	cfg := config.Config{RemoteAccount: "previous", Accounts: []config.Account{{Name: "work", Home: root}}}
	code, err := useCommand(config.Paths{}, &cfg, []string{"work"}, true)
	if code == 0 || err == nil || cfg.RemoteAccount != "previous" {
		t.Fatalf("selection changed despite missing login: %d %v %#v", code, err, cfg)
	}
}

type updateRegistryFixture struct{}

func (updateRegistryFixture) RoundTrip(r *http.Request) (*http.Response, error) {
	return &http.Response{StatusCode: 200, Header: make(http.Header), Body: io.NopCloser(strings.NewReader(`{"version":"0.162.1"}`)), Request: r}, nil
}
