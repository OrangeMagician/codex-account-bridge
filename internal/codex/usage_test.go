package codex

import (
	"os"
	"path/filepath"
	"strings"
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

func TestConsumeUsageResetCreditUsesOfficialIdempotentMethod(t *testing.T) {
	root := t.TempDir()
	fake := filepath.Join(root, "codex-real")
	observed := filepath.Join(root, "observed")
	script := `#!/bin/sh
printf '%s\n' "$CODEX_HOME" > "$CAB_TEST_OUTPUT"
IFS= read -r initialize
printf '%s\n' '{"id":1,"result":{}}'
IFS= read -r initialized
IFS= read -r account
printf '%s\n' '{"id":2,"result":{"account":{"type":"chatgpt","planType":"plus"}}}'
IFS= read -r reset
printf '%s\n' "$reset" >> "$CAB_TEST_OUTPUT"
printf '%s\n' '{"id":3,"result":{"outcome":"reset"}}'
`
	if err := os.WriteFile(fake, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("CAB_REAL_CODEX", fake)
	t.Setenv("CAB_TEST_OUTPUT", observed)
	home := filepath.Join(root, "account")
	outcome, err := ConsumeUsageResetCredit(home, "123e4567-e89b-12d3-a456-426614174000")
	if err != nil {
		t.Fatal(err)
	}
	if outcome != UsageResetCompleted {
		t.Fatalf("outcome = %q", outcome)
	}
	data, err := os.ReadFile(observed)
	if err != nil {
		t.Fatal(err)
	}
	request := string(data)
	if !strings.Contains(request, home+"\n") ||
		!strings.Contains(request, `"method":"account/rateLimitResetCredit/consume"`) ||
		!strings.Contains(request, `"idempotencyKey":"123e4567-e89b-12d3-a456-426614174000"`) {
		t.Fatalf("unexpected reset request %q", request)
	}
}

func TestConsumeUsageResetCreditRejectsInvalidIdempotencyKey(t *testing.T) {
	if _, err := ConsumeUsageResetCredit("/tmp/account", "not valid"); err == nil {
		t.Fatal("expected invalid idempotency key error")
	}
}

func TestProbeUsageUsesEphemeralLowestCostRequest(t *testing.T) {
	root := t.TempDir()
	fake := filepath.Join(root, "codex-real")
	observed := filepath.Join(root, "observed")
	script := `#!/bin/sh
printf '%s\n' "$@" > "$CAB_TEST_OUTPUT"
exit 0
`
	if err := os.WriteFile(fake, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("CAB_REAL_CODEX", fake)
	t.Setenv("CAB_TEST_OUTPUT", observed)
	if err := ProbeUsage(filepath.Join(root, "account"), "gpt-5.6-luna"); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(observed)
	if err != nil {
		t.Fatal(err)
	}
	args := string(data)
	for _, expected := range []string{
		"exec", "--ephemeral", "--ignore-user-config", "--sandbox", "read-only",
		"--model", "gpt-5.6-luna", "--cd", "Reply exactly OK.",
	} {
		if !strings.Contains(args, expected) {
			t.Fatalf("probe args %q do not contain %q", args, expected)
		}
	}
}
