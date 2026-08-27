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
	Elapsed    string `json:"elapsed"`
	TTY        string `json:"tty"`
	State      string `json:"state"`
	Executable string `json:"executable"`
}

func List() ([]Process, error) {
	cmd := exec.Command("pgrep", "-x", "codex")
	out, err := cmd.Output()
	if err != nil {
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) && exitErr.ExitCode() == 1 {
			return []Process{}, nil
		}
		return nil, fmt.Errorf("list Codex processes: %w", err)
	}
	var result []Process
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
	for _, pid := range pids {
		process, ok := byPID[pid]
		if !ok {
			continue
		}
		if filepath.Base(process.Executable) != "codex" {
			return fmt.Errorf("PID %d is no longer an official Codex process", pid)
		}
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
			if _, ok := byPID[process.PID]; ok {
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

func inspect(pid int) (Process, bool) {
	out, err := exec.Command("ps", "-p", strconv.Itoa(pid), "-o", "ppid=,etime=,tty=,stat=,comm=").Output()
	if err != nil {
		return Process{}, false
	}
	return parsePS(pid, string(out))
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
