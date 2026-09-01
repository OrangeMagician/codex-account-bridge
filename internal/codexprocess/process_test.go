package codexprocess

import "testing"

import "time"

func TestParsePSAcceptsOnlyLiveExactCodex(t *testing.T) {
	process, ok := parsePS(42, "7 05:12 pts/3 Sl+ /opt/codex\n")
	if !ok || process.PID != 42 || process.ParentPID != 7 || process.Elapsed != "05:12" || process.TTY != "pts/3" {
		t.Fatalf("unexpected process: %#v ok=%t", process, ok)
	}
	for _, value := range []string{
		"7 05:12 pts/3 Z+ /opt/codex\n",
		"7 05:12 pts/3 UE /opt/codex\n",
		"7 05:12 pts/3 Sl+ /opt/not-codex\n",
		"invalid\n",
	} {
		if _, ok := parsePS(42, value); ok {
			t.Fatalf("accepted %q", value)
		}
	}
}

func TestSameIdentityIncludesProcessFingerprint(t *testing.T) {
	base := Process{PID: 42, ParentPID: 7, UID: 501, StartedAt: "Sat Aug 29 12:00:00 2026", Executable: "/opt/codex"}
	if !sameIdentity(base, base) {
		t.Fatal("identical processes should match")
	}
	changed := base
	changed.ParentPID++
	if !sameIdentity(base, changed) || sameSignalTarget(base, changed) {
		t.Fatal("reparenting should preserve process identity but reject the pre-signal target")
	}
	changed = base
	changed.StartedAt = "Sat Aug 29 12:00:01 2026"
	if sameIdentity(base, changed) {
		t.Fatal("reused PID should not match the original process identity")
	}
}

func TestWaitForExitReturnsImmediatelyWithoutTargets(t *testing.T) {
	exited, err := waitForExit(map[int]Process{}, time.Second)
	if err != nil || !exited {
		t.Fatalf("waitForExit() = %t, %v; want true, nil", exited, err)
	}
}
