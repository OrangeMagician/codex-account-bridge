//go:build darwin

package codexprocess

import (
	"encoding/binary"
	"errors"
	"path/filepath"
	"syscall"
	"unsafe"
)

func processExecutablePath(pid int) (string, error) {
	args, _, err := processLaunchData(pid)
	if err != nil {
		return "", err
	}
	if len(args) == 0 {
		return "", errors.New("missing executable")
	}
	if filepath.IsAbs(args[0]) {
		return filepath.EvalSymlinks(args[0])
	}
	return args[0], nil
}

func processLaunchData(pid int) ([]string, []string, error) {
	mib := [3]int32{1, 49, int32(pid)} // CTL_KERN, KERN_PROCARGS2
	var size uintptr
	_, _, errno := syscall.Syscall6(syscall.SYS___SYSCTL, uintptr(unsafe.Pointer(&mib[0])), 3, 0, uintptr(unsafe.Pointer(&size)), 0, 0)
	if errno != 0 {
		return nil, nil, errno
	}
	if size < 4 || size > 1<<20 {
		return nil, nil, errors.New("invalid process data size")
	}
	data := make([]byte, size)
	_, _, errno = syscall.Syscall6(syscall.SYS___SYSCTL, uintptr(unsafe.Pointer(&mib[0])), 3, uintptr(unsafe.Pointer(&data[0])), uintptr(unsafe.Pointer(&size)), 0, 0)
	if errno != 0 {
		return nil, nil, errno
	}
	if size < 4 || size > uintptr(len(data)) {
		return nil, nil, errors.New("invalid returned process data size")
	}
	data = data[:size]
	argc := int(binary.LittleEndian.Uint32(data[:4]))
	if argc < 1 || argc > len(data) {
		return nil, nil, errors.New("invalid process argc")
	}
	i := 4
	next := func() (string, bool) {
		start := i
		for i < len(data) && data[i] != 0 {
			i++
		}
		if i >= len(data) {
			return "", false
		}
		v := string(data[start:i])
		i++
		return v, true
	}
	if _, ok := next(); !ok {
		return nil, nil, errors.New("missing executable")
	}
	for i < len(data) && data[i] == 0 {
		i++
	}
	args := make([]string, 0, argc)
	for n := 0; n < argc; n++ {
		v, ok := next()
		if !ok {
			return nil, nil, errors.New("truncated process data")
		}
		args = append(args, v)
	}
	env := []string{}
	for i < len(data) && data[i] != 0 {
		v, ok := next()
		if !ok {
			return nil, nil, errors.New("truncated environment")
		}
		env = append(env, v)
	}
	return args, env, nil
}
