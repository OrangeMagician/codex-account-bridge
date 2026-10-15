package app

import (
	"github.com/OrangeMagician/codex-account-bridge/internal/config"
	"testing"
)

func TestRemoteVerificationCannotVerifyDifferentSavedSelection(t *testing.T) {
	cfg := config.Config{RemoteAccount: "old", Accounts: []config.Account{{Name: "selected", Home: "/accounts/selected"}}}
	code, err := remoteVerifyCommand(cfg, []string{"--account", "selected", "--json"})
	if code == 0 || err == nil {
		t.Fatalf("wrong saved selection verified: %d %v", code, err)
	}
}
