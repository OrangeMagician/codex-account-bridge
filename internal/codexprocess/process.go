package codexprocess

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

type Process struct {
	PID        int    `json:"pid"`
	ParentPID  int    `json:"parent_pid"`
	UID        int    `json:"uid"`
	StartedAt  string `json:"started_at"`
	Elapsed    string `json:"elapsed"`
	TTY        string `json:"tty"`
	State      string `json:"state"`
	Executable string `json:"executable"`
}

func List() ([]Process, error) {
	pgrep, err := systemTool("pgrep")
	if err != nil {
		return nil, err
	}
	cmd := exec.Command(pgrep, "-x", "codex")
	out, err := cmd.Output()
	if err != nil {
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) && exitErr.ExitCode() == 1 {
			return []Process{}, nil
		}
		return nil, fmt.Errorf("list Codex processes: %w", err)
	}
	result := []Process{}
	for _, value := range strings.Fields(string(out)) {
		pid, err := strconv.Atoi(value)
		if err != nil {
			continue
		}
		process, ok := inspect(pid)
		if ok {
			result = append(result, process)
		}
	}
	return result, nil
}

func Stop(pids []int) error {
	current, err := List()
	if err != nil {
		return err
	}
	byPID := make(map[int]Process, len(current))
	for _, process := range current {
		byPID[process.PID] = process
	}
	targets := make(map[int]Process, len(pids))
	for _, pid := range pids {
		process, ok := byPID[pid]
		if !ok {
			continue
		}
		if filepath.Base(process.Executable) != "codex" {
			return fmt.Errorf("PID %d is no longer an official Codex process", pid)
		}
		latest, ok := inspect(pid)
		if !ok || latest.UID != os.Getuid() || !sameSignalTarget(process, latest) {
			return fmt.Errorf("PID %d changed identity before it could be stopped", pid)
		}
		targets[pid] = process
		target, err := os.FindProcess(pid)
		if err != nil {
			return err
		}
		if err := target.Signal(syscall.SIGTERM); err != nil && !errors.Is(err, os.ErrProcessDone) {
			return fmt.Errorf("stop Codex PID %d: %w", pid, err)
		}
	}
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		remaining, err := List()
		if err != nil {
			return err
		}
		alive := false
		for _, process := range remaining {
			if original, ok := targets[process.PID]; ok && sameIdentity(original, process) {
				alive = true
				break
			}
		}
		if !alive {
			return nil
		}
		time.Sleep(100 * time.Millisecond)
	}
	return errors.New("one or more Codex processes did not exit after a normal stop request")
}

func sameIdentity(left, right Process) bool {
	return left.PID == right.PID &&
		left.UID == right.UID &&
		left.StartedAt == right.StartedAt &&
		left.Executable == right.Executable
}

func sameSignalTarget(left, right Process) bool {
	return sameIdentity(left, right) && left.ParentPID == right.ParentPID
}

func inspect(pid int) (Process, bool) {
	ps, err := systemTool("ps")
	if err != nil {
		return Process{}, false
	}
	out, err := exec.Command(ps, "-p", strconv.Itoa(pid), "-o", "ppid=,etime=,tty=,stat=,comm=").Output()
	if err != nil {
		return Process{}, false
	}
	process, ok := parsePS(pid, string(out))
	if !ok {
		return Process{}, false
	}
	fingerprint, err := exec.Command(ps, "-p", strconv.Itoa(pid), "-o", "uid=,lstart=").Output()
	if err != nil {
		return Process{}, false
	}
	fields := strings.Fields(string(fingerprint))
	if len(fields) < 6 {
		return Process{}, false
	}
	uid, err := strconv.Atoi(fields[0])
	if err != nil || uid != os.Getuid() {
		return Process{}, false
	}
	process.UID = uid
	process.StartedAt = strings.Join(fields[1:], " ")
	return process, true
}

func systemTool(name string) (string, error) {
	candidates := map[string][]string{
		"pgrep": {"/usr/bin/pgrep", "/bin/pgrep"},
		"ps":    {"/bin/ps", "/usr/bin/ps"},
	}[name]
	for _, path := range candidates {
		if info, err := os.Stat(path); err == nil && !info.IsDir() && info.Mode().Perm()&0o111 != 0 {
			return path, nil
		}
	}
	return "", fmt.Errorf("required system tool %s was not found in a trusted location", name)
}

func parsePS(pid int, output string) (Process, bool) {
	fields := strings.Fields(output)
	if len(fields) < 5 {
		return Process{}, false
	}
	if strings.HasPrefix(fields[3], "Z") || strings.Contains(fields[3], "E") {
		return Process{}, false
	}
	ppid, err := strconv.Atoi(fields[0])
	if err != nil {
		return Process{}, false
	}
	executable := strings.Join(fields[4:], " ")
	if filepath.Base(executable) != "codex" {
		return Process{}, false
	}
	return Process{PID: pid, ParentPID: ppid, Elapsed: fields[1], TTY: fields[2], State: fields[3], Executable: executable}, true
}
