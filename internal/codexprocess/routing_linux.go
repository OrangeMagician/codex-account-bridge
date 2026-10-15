//go:build linux

package codexprocess

import (
	"fmt"
	"io"
	"os"
	"strings"
)

func processLaunchData(pid int) ([]string, []string, error) {
	read := func(name string) ([]string, error) {
		f, err := os.Open(fmt.Sprintf("/proc/%d/%s", pid, name))
		if err != nil {
			return nil, err
		}
		defer f.Close()
		data, err := io.ReadAll(io.LimitReader(f, (1<<20)+1))
		if err != nil {
			return nil, err
		}
		if len(data) > 1<<20 {
			return nil, fmt.Errorf("process environment exceeds limit")
		}
		return strings.Split(strings.TrimRight(string(data), "\x00"), "\x00"), nil
	}
	args, err := read("cmdline")
	if err != nil {
		return nil, nil, err
	}
	env, err := read("environ")
	return args, env, err
}
