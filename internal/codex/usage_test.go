package codex

import (
	"os"
	"path/filepath"
	"testing"
)

func TestReadUsageUsesOfficialAppServerWithoutExposingAccountEmail(t *testing.T) {
	root := t.TempDir()
	fake := filepath.Join(root, "codex-real")
	observed := filepath.Join(root, "observed")
	script := `#!/bin/sh
printf '%s\n' "$CODEX_HOME" > "$CAB_TEST_OUTPUT"
printf '%s\n' "$@" >> "$CAB_TEST_OUTPUT"
IFS= read -r initialize
printf '%s\n' '{"id":1,"result":{"userAgent":"test","codexHome":"/tmp/test"}}'
IFS= read -r initialized
IFS= read -r account
printf '%s\n' '{"id":2,"result":{"account":{"type":"chatgpt","email":"private@example.com","planType":"plus"},"requiresOpenaiAuth":true}}'
IFS= read -r limits
printf '%s\n' '{"id":3,"result":{"rateLimits":{"limitId":"codex","limitName":"Codex","primary":{"usedPercent":42.5,"windowDurationMins":10080,"resetsAt":1788139274},"secondary":null,"credits":{"hasCredits":true,"unlimited":false,"balance":"12.50"},"individualLimit":null,"spendControlReached":false,"planType":"plus","rateLimitReachedType":null},"rateLimitsByLimitId":{"codex":{"limitId":"codex","limitName":"Codex","primary":{"usedPercent":42.5,"windowDurationMins":10080,"resetsAt":1788139274},"secondary":null,"credits":{"hasCredits":true,"unlimited":false,"balance":"12.50"},"individualLimit":null,"spendControlReached":false,"planType":"plus","rateLimitReachedType":null}},"rateLimitResetCredits":{"availableCount":1,"credits":[{"id":"secret-id","resetType":"codexRateLimits","status":"available","grantedAt":1788000000,"expiresAt":1789000000,"title":"Reset","description":"One reset"}]}}}'
`
	if err := os.WriteFile(fake, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("CAB_REAL_CODEX", fake)
	t.Setenv("CAB_TEST_OUTPUT", observed)
	home := filepath.Join(root, "account")
	usage, err := ReadUsage(home)
	if err != nil {
		t.Fatal(err)
	}
	if usage.PlanType != "plus" || usage.RateLimits.Primary == nil || usage.RateLimits.Primary.UsedPercent != 42.5 {
		t.Fatalf("unexpected usage: %#v", usage)
	}
	if usage.ResetCredits == nil || usage.ResetCredits.AvailableCount != 1 || len(usage.ResetCredits.Credits) != 1 {
		t.Fatalf("unexpected reset credits: %#v", usage.ResetCredits)
	}
	data, err := os.ReadFile(observed)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != home+"\napp-server\n" {
		t.Fatalf("official command = %q", data)
	}
}

func TestReadUsageRejectsNonChatGPTAuthentication(t *testing.T) {
	root := t.TempDir()
	fake := filepath.Join(root, "codex-real")
	script := `#!/bin/sh
IFS= read -r initialize
printf '%s\n' '{"id":1,"result":{}}'
IFS= read -r initialized
IFS= read -r account
printf '%s\n' '{"id":2,"result":{"account":{"type":"apiKey"},"requiresOpenaiAuth":true}}'
`
	if err := os.WriteFile(fake, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("CAB_REAL_CODEX", fake)
	if _, err := ReadUsage(filepath.Join(root, "account")); err == nil {
		t.Fatal("expected ChatGPT login requirement")
	}
}
