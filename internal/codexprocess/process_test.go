package codexprocess

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"syscall"
	"testing"
	"time"
)

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
	if !sameIdentity(base, changed) {
		t.Fatal("reparenting should preserve process identity")
	}
	changed = base
	changed.StartedAt = "Sat Aug 29 12:00:01 2026"
	if sameIdentity(base, changed) {
		t.Fatal("reused PID should not match the original process identity")
	}
}

func TestSignalCheckedHandlesStopRaces(t *testing.T) {
	base := Process{PID: 42, ParentPID: 7, UID: os.Getuid(), StartedAt: "Sat Aug 29 12:00:00 2026", Executable: "/opt/codex"}
	inspectionErr := errors.New("ps failed")
	for _, signal := range []syscall.Signal{syscall.SIGTERM, syscall.SIGKILL} {
		for _, test := range []struct {
			name          string
			change        func(*Process)
			gone          bool
			inspectionErr error
			signalErr     error
			wantSignal    bool
			wantErr       bool
		}{
			{name: "unchanged", wantSignal: true},
			{name: "reparented", change: func(p *Process) { p.ParentPID = 1 }, wantSignal: true},
			{name: "exited before inspection", gone: true},
			{name: "exited before signal", signalErr: os.ErrProcessDone, wantSignal: true},
			{name: "ESRCH before signal", signalErr: syscall.ESRCH, wantSignal: true},
			{name: "inspection failed", inspectionErr: inspectionErr, wantErr: true},
			{name: "signal denied", signalErr: syscall.EPERM, wantSignal: true, wantErr: true},
			{name: "PID reused", change: func(p *Process) { p.StartedAt = "Sat Aug 29 12:00:01 2026" }, wantErr: true},
			{name: "different PID", change: func(p *Process) { p.PID++ }, wantErr: true},
			{name: "different UID", change: func(p *Process) { p.UID++ }, wantErr: true},
			{name: "different executable", change: func(p *Process) { p.Executable = "/other/codex" }, wantErr: true},
		} {
			t.Run(fmt.Sprintf("%s/%s", signal, test.name), func(t *testing.T) {
				latest := base
				if test.change != nil {
					test.change(&latest)
				}
				signaled := false
				err := signalChecked(base, signal, func(pid int) (Process, bool, error) {
					if pid != base.PID {
						t.Fatalf("inspected PID %d, want %d", pid, base.PID)
					}
					return latest, !test.gone, test.inspectionErr
				}, func(pid int, actual syscall.Signal) error {
					signaled = true
					if pid != base.PID || actual != signal {
						t.Fatalf("sent %s to PID %d, want %s to %d", actual, pid, signal, base.PID)
					}
					return test.signalErr
				})
				if (err != nil) != test.wantErr || signaled != test.wantSignal {
					t.Fatalf("error = %v, signaled = %t; want error = %t, signaled = %t", err, signaled, test.wantErr, test.wantSignal)
				}
				if test.inspectionErr != nil && !errors.Is(err, test.inspectionErr) {
					t.Fatalf("inspection failure was not preserved: %v", err)
				}
			})
		}
	}
}

func TestParseInspectionUsesSingleSnapshot(t *testing.T) {
	output := fmt.Sprintf("%d Sat Aug 29 12:00:00 2026 7 05:12 pts/3 Sl+ /opt/my tools/codex\n", os.Getuid())
	process, ok, err := parseInspection(42, output)
	if err != nil || !ok || process.UID != os.Getuid() || process.StartedAt != "Sat Aug 29 12:00:00 2026" || process.ParentPID != 7 || process.Executable != "/opt/my tools/codex" {
		t.Fatalf("unexpected snapshot: %#v, ok=%t, err=%v", process, ok, err)
	}
	for _, output := range []string{"", "invalid", "invalid Sat Aug 29 12:00:00 2026 7 05:12 pts/3 Sl+ codex"} {
		if _, ok, err := parseInspection(42, output); err == nil || ok {
			t.Fatalf("malformed snapshot treated as an exited process: %q, ok=%t, err=%v", output, ok, err)
		}
	}
	for _, output := range []string{
		fmt.Sprintf("%d Sat Aug 29 12:00:00 2026 7 05:12 pts/3 Z codex", os.Getuid()),
		fmt.Sprintf("%d Sat Aug 29 12:00:00 2026 7 05:12 pts/3 S other", os.Getuid()),
		fmt.Sprintf("%d Sat Aug 29 12:00:00 2026 7 05:12 pts/3 S codex", os.Getuid()+1),
	} {
		if _, ok, err := parseInspection(42, output); err != nil || ok {
			t.Fatalf("unexpected result for ineligible process: %q, ok=%t, err=%v", output, ok, err)
		}
	}
}

func TestInspectMissingProcess(t *testing.T) {
	ps, err := systemTool("ps")
	if err != nil {
		t.Fatal(err)
	}
	command := exec.Command(ps, "-p", strconv.Itoa(os.Getpid()), "-o", "pid=")
	if err := command.Run(); err != nil {
		t.Fatal(err)
	}
	// Use a reaped child PID: an out-of-range PID is an actual ps error on macOS.
	if _, ok, err := inspect(command.Process.Pid); err != nil || ok {
		t.Fatalf("inspect(missing) = ok=%t, err=%v; want false, nil", ok, err)
	}
}

func TestWaitForExitReturnsImmediatelyWithoutTargets(t *testing.T) {
	exited, err := waitForExit(map[int]Process{}, time.Second)
	if err != nil || !exited {
		t.Fatalf("waitForExit() = %t, %v; want true, nil", exited, err)
	}
}
