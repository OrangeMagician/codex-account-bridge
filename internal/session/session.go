package session

import (
	"bytes"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/OrangeMagician/codex-account-bridge/internal/config"
)

var historyDirectoryNames = []string{"sessions", "archived_sessions"}

const operationJournalName = "sessions-operation.json"

type operationJournal struct {
	Version   int               `json:"version"`
	Operation string            `json:"operation"`
	Shared    string            `json:"shared"`
	Items     []operationTarget `json:"items"`
}

type operationTarget struct {
	Target string `json:"target"`
	Shared string `json:"shared"`
	Backup string `json:"backup,omitempty"`
	Stage  string `json:"stage,omitempty"`
}

type LegacyReport struct {
	SourceHome       string `json:"source_home"`
	Sessions         int    `json:"sessions"`
	ArchivedSessions int    `json:"archived_sessions"`
}

func LegacyStatus(cfg config.Config, sourceHome string) (LegacyReport, error) {
	report := LegacyReport{SourceHome: sourceHome}
	if cfg.SharedSessionsDir == "" {
		return report, errors.New("session sharing is not enabled")
	}
	for _, account := range cfg.Accounts {
		if filepath.Clean(account.Home) == filepath.Clean(sourceHome) {
			return report, nil
		}
	}
	counts := []*int{&report.Sessions, &report.ArchivedSessions}
	for index, name := range historyDirectoryNames {
		source := filepath.Join(sourceHome, name)
		shared := sharedHistoryDir(cfg.SharedSessionsDir, name)
		if sameResolvedPath(source, shared) {
			continue
		}
		count, err := pendingRegularFiles(source, shared)
		if err != nil {
			return report, err
		}
		*counts[index] = count
	}
	return report, nil
}

func pendingRegularFiles(sourceRoot, targetRoot string) (int, error) {
	count := 0
	err := filepath.WalkDir(sourceRoot, func(source string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if !entry.Type().IsRegular() {
			return nil
		}
		relative, err := filepath.Rel(sourceRoot, source)
		if err != nil {
			return err
		}
		if _, err := os.Lstat(filepath.Join(targetRoot, relative)); errors.Is(err, fs.ErrNotExist) {
			count++
		} else if err != nil {
			return err
		}
		return nil
	})
	if errors.Is(err, fs.ErrNotExist) {
		return 0, nil
	}
	return count, err
}

func ImportLegacy(paths config.Paths, cfg config.Config, sourceHome string) (LegacyReport, error) {
	report, err := LegacyStatus(cfg, sourceHome)
	if err != nil {
		return report, err
	}
	unlock, err := lock(paths.DataDir)
	if err != nil {
		return report, err
	}
	defer unlock()
	for _, name := range historyDirectoryNames {
		if err := mergeTree(filepath.Join(sourceHome, name), sharedHistoryDir(cfg.SharedSessionsDir, name)); err != nil {
			return report, fmt.Errorf("import legacy %s: %w", name, err)
		}
	}
	return report, nil
}

// Recover completes or rolls back a session operation interrupted between its
// filesystem phase and the durable configuration save.
func Recover(paths config.Paths, cfg config.Config) error {
	journal, err := readJournal(paths)
	if errors.Is(err, fs.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if err := validateJournal(journal, cfg); err != nil {
		return err
	}
	unlock, err := lock(paths.DataDir)
	if err != nil {
		return err
	}
	defer unlock()

	switch journal.Operation {
	case "enable":
		if filepath.Clean(cfg.SharedSessionsDir) != filepath.Clean(journal.Shared) {
			if err := rollbackEnableTargets(journal.Items); err != nil {
				return fmt.Errorf("recover interrupted session enable: %w", err)
			}
		}
	case "disable":
		if cfg.SharedSessionsDir != "" {
			if err := rollbackDisableTargets(journal.Items); err != nil {
				return fmt.Errorf("recover interrupted session disable: %w", err)
			}
		}
	default:
		return fmt.Errorf("unknown session operation journal type %q", journal.Operation)
	}
	return clearJournal(paths)
}

// RecoveryStatus validates any durable session journal without changing state.
func RecoveryStatus(paths config.Paths, cfg config.Config) (bool, error) {
	journal, err := readJournal(paths)
	if errors.Is(err, fs.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if err := validateJournal(journal, cfg); err != nil {
		return false, err
	}
	return true, nil
}

// PrepareEnable performs the reversible filesystem part of enabling sharing.
// The caller must invoke Commit after saving cfg or Rollback on any save error.
func PrepareEnable(paths config.Paths, cfg *config.Config) (config.Mutation, error) {
	unlock, err := lock(paths.DataDir)
	if err != nil {
		return config.Mutation{}, err
	}
	fail := func(err error) (config.Mutation, error) {
		unlock()
		return config.Mutation{}, err
	}
	sharedSessions := cfg.SharedSessionsDir
	if sharedSessions == "" {
		sharedSessions = filepath.Join(paths.DataDir, "shared", "sessions")
	}
	if !filepath.IsAbs(sharedSessions) || filepath.Clean(sharedSessions) == string(filepath.Separator) {
		return fail(fmt.Errorf("unsafe shared sessions directory: %s", sharedSessions))
	}
	for _, name := range historyDirectoryNames {
		shared := sharedHistoryDir(sharedSessions, name)
		if err := secureDir(shared); err != nil {
			return fail(err)
		}
		for _, account := range cfg.Accounts {
			if err := mergeTree(filepath.Join(account.Home, name), shared); err != nil {
				return fail(fmt.Errorf("merge %s: %w", filepath.Join(account.Home, name), err))
			}
		}
	}

	stamp := time.Now().UTC().Format("20060102T150405.000000000Z")
	items := []operationTarget{}
	for _, name := range historyDirectoryNames {
		shared := sharedHistoryDir(sharedSessions, name)
		for _, account := range cfg.Accounts {
			if err := secureDir(account.Home); err != nil {
				return fail(err)
			}
			target := filepath.Join(account.Home, name)
			info, err := os.Lstat(target)
			backup := ""
			if err == nil {
				if info.Mode()&os.ModeSymlink != 0 {
					if sameResolvedPath(target, shared) {
						continue
					}
					return fail(fmt.Errorf("refusing existing %s symlink: %s", name, target))
				}
				if !info.IsDir() {
					return fail(fmt.Errorf("%s path is not a directory: %s", name, target))
				}
				backup = target + ".cab-backup-" + stamp
				if _, err := os.Lstat(backup); err == nil {
					return fail(fmt.Errorf("backup path already exists: %s", backup))
				} else if !errors.Is(err, fs.ErrNotExist) {
					return fail(err)
				}
			} else if !errors.Is(err, fs.ErrNotExist) {
				return fail(err)
			}
			items = append(items, operationTarget{Target: target, Shared: shared, Backup: backup})
		}
	}
	journal := operationJournal{Version: 1, Operation: "enable", Shared: sharedSessions, Items: items}
	if err := writeJournal(paths, journal); err != nil {
		return fail(err)
	}
	abort := func(cause error) (config.Mutation, error) {
		return fail(errors.Join(cause, rollbackEnableOperation(paths, items)))
	}
	for _, item := range items {
		if item.Backup != "" {
			if err := os.Rename(item.Target, item.Backup); err != nil {
				return abort(err)
			}
		}
		if err := os.Symlink(item.Shared, item.Target); err != nil {
			return abort(err)
		}
	}
	previous := cfg.SharedSessionsDir
	cfg.SharedSessionsDir = sharedSessions
	finished := false
	finish := func(action func() error) error {
		if finished {
			return nil
		}
		finished = true
		defer unlock()
		return action()
	}
	return config.Mutation{
		Rollback: func() error {
			cfg.SharedSessionsDir = previous
			return finish(func() error { return rollbackEnableOperation(paths, items) })
		},
		Commit: func() error { return finish(func() error { return clearJournal(paths) }) },
	}, nil
}

// PrepareDisable performs the reversible filesystem part of disabling sharing.
func PrepareDisable(paths config.Paths, cfg *config.Config) (config.Mutation, error) {
	if cfg.SharedSessionsDir == "" {
		return config.Mutation{}, errors.New("session sharing is not enabled")
	}
	unlock, err := lock(paths.DataDir)
	if err != nil {
		return config.Mutation{}, err
	}
	fail := func(err error) (config.Mutation, error) {
		unlock()
		return config.Mutation{}, err
	}
	stamp := time.Now().UTC().Format("20060102T150405.000000000Z")
	items := []operationTarget{}
	for _, name := range historyDirectoryNames {
		shared := sharedHistoryDir(cfg.SharedSessionsDir, name)
		for _, account := range cfg.Accounts {
			target := filepath.Join(account.Home, name)
			info, err := os.Lstat(target)
			if errors.Is(err, fs.ErrNotExist) && name == "archived_sessions" {
				continue
			}
			if err != nil {
				cleanupOperationStages(items)
				return fail(err)
			}
			if info.Mode()&os.ModeSymlink == 0 {
				if name == "archived_sessions" && info.IsDir() {
					continue
				}
				cleanupOperationStages(items)
				return fail(fmt.Errorf("refusing unexpected non-symlink: %s", target))
			}
			if !sameResolvedPath(target, shared) {
				cleanupOperationStages(items)
				return fail(fmt.Errorf("refusing unexpected %s target: %s", name, target))
			}
			stage := filepath.Join(account.Home, ".cab-"+name+"-disable-"+stamp)
			if _, err := os.Lstat(stage); err == nil {
				cleanupOperationStages(items)
				return fail(fmt.Errorf("staging path already exists: %s", stage))
			} else if !errors.Is(err, fs.ErrNotExist) {
				cleanupOperationStages(items)
				return fail(err)
			}
			if err := secureDir(stage); err != nil {
				cleanupOperationStages(items)
				return fail(err)
			}
			if err := mergeTree(shared, stage); err != nil {
				cleanupOperationStages(items)
				return fail(err)
			}
			items = append(items, operationTarget{Target: target, Stage: stage, Shared: shared})
		}
	}
	journal := operationJournal{Version: 1, Operation: "disable", Shared: cfg.SharedSessionsDir, Items: items}
	if err := writeJournal(paths, journal); err != nil {
		cleanupOperationStages(items)
		return fail(err)
	}
	abort := func(cause error) (config.Mutation, error) {
		return fail(errors.Join(cause, rollbackDisableOperation(paths, items)))
	}
	for _, item := range items {
		if err := os.Remove(item.Target); err != nil {
			return abort(err)
		}
		if err := os.Rename(item.Stage, item.Target); err != nil {
			return abort(err)
		}
	}
	previous := cfg.SharedSessionsDir
	cfg.SharedSessionsDir = ""
	finished := false
	finish := func(action func() error) error {
		if finished {
			return nil
		}
		finished = true
		defer unlock()
		return action()
	}
	return config.Mutation{
		Rollback: func() error {
			cfg.SharedSessionsDir = previous
			return finish(func() error { return rollbackDisableOperation(paths, items) })
		},
		Commit: func() error { return finish(func() error { return clearJournal(paths) }) },
	}, nil
}

func Enable(paths config.Paths, cfg *config.Config) error {
	mutation, err := PrepareEnable(paths, cfg)
	if err != nil {
		return err
	}
	return mutation.Commit()
}

func Disable(paths config.Paths, cfg *config.Config) error {
	mutation, err := PrepareDisable(paths, cfg)
	if err != nil {
		return err
	}
	return mutation.Commit()
}

func sharedHistoryDir(sharedSessions, name string) string {
	if name == "sessions" {
		return sharedSessions
	}
	return filepath.Join(filepath.Dir(sharedSessions), name)
}

func mergeTree(source, destination string) error {
	info, err := os.Lstat(source)
	if errors.Is(err, fs.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if info.Mode()&os.ModeSymlink != 0 {
		if !sameResolvedPath(source, destination) {
			return fmt.Errorf("refusing source symlink %s", source)
		}
		return nil
	}
	if !info.IsDir() {
		return fmt.Errorf("source is not a directory")
	}
	return filepath.WalkDir(source, func(path string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		relative, err := filepath.Rel(source, path)
		if err != nil {
			return err
		}
		target := filepath.Join(destination, relative)
		if entry.Type()&os.ModeSymlink != 0 {
			return fmt.Errorf("refusing nested symlink %s", path)
		}
		if entry.IsDir() {
			return secureDir(target)
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		if !info.Mode().IsRegular() {
			return fmt.Errorf("refusing non-regular session file %s", path)
		}
		if existing, err := os.Lstat(target); err == nil {
			if !existing.Mode().IsRegular() {
				return fmt.Errorf("destination is not regular: %s", target)
			}
			same, err := sameFile(path, target)
			if err != nil {
				return err
			}
			if !same {
				return fmt.Errorf("session collision at %s", target)
			}
			return nil
		} else if !errors.Is(err, fs.ErrNotExist) {
			return err
		}
		return copyFile(path, target)
	})
}

func copyFile(source, target string) error {
	input, err := os.Open(source)
	if err != nil {
		return err
	}
	defer input.Close()
	output, err := os.OpenFile(target, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return err
	}
	ok := false
	defer func() {
		output.Close()
		if !ok {
			_ = os.Remove(target)
		}
	}()
	if _, err := io.Copy(output, input); err != nil {
		return err
	}
	if err := output.Sync(); err != nil {
		return err
	}
	ok = true
	return nil
}

func sameFile(left, right string) (bool, error) {
	hash := func(path string) ([32]byte, error) {
		file, err := os.Open(path)
		if err != nil {
			return [32]byte{}, err
		}
		defer file.Close()
		digest := sha256.New()
		if _, err := io.Copy(digest, file); err != nil {
			return [32]byte{}, err
		}
		var result [32]byte
		copy(result[:], digest.Sum(nil))
		return result, nil
	}
	a, err := hash(left)
	if err != nil {
		return false, err
	}
	b, err := hash(right)
	return a == b, err
}

func secureDir(path string) error {
	if !filepath.IsAbs(path) || filepath.Clean(path) == string(filepath.Separator) {
		return fmt.Errorf("refusing unsafe directory: %s", path)
	}
	if err := rejectSymlinkComponents(path); err != nil {
		return err
	}
	if err := os.MkdirAll(path, 0o700); err != nil {
		return err
	}
	if err := rejectSymlinkComponents(path); err != nil {
		return err
	}
	return os.Chmod(path, 0o700)
}

func rejectSymlinkComponents(path string) error {
	info, err := os.Lstat(filepath.Clean(path))
	if errors.Is(err, fs.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
		return fmt.Errorf("refusing unsafe directory: %s", path)
	}
	return nil
}

func lock(dataDir string) (func(), error) {
	return lockWithMode(dataDir, syscall.LOCK_EX)
}

// AcquireRunLease prevents a session-layout transaction from starting while a
// CAB-launched Codex process may be reading or writing session history.
func AcquireRunLease(paths config.Paths) (func(), error) {
	return lockWithMode(paths.DataDir, syscall.LOCK_SH)
}

func lockWithMode(dataDir string, mode int) (func(), error) {
	if err := secureDir(dataDir); err != nil {
		return nil, err
	}
	path := filepath.Join(dataDir, "sessions.lock")
	if info, err := os.Lstat(path); err == nil {
		if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
			return nil, fmt.Errorf("refusing unsafe session lock: %s", path)
		}
	} else if !errors.Is(err, fs.ErrNotExist) {
		return nil, err
	}
	fd, err := syscall.Open(path, syscall.O_CREAT|syscall.O_RDWR|syscall.O_NOFOLLOW, 0o600)
	if err != nil {
		return nil, err
	}
	file := os.NewFile(uintptr(fd), path)
	fail := func(err error) (func(), error) {
		_ = file.Close()
		return nil, err
	}
	var stat syscall.Stat_t
	if err := syscall.Fstat(fd, &stat); err != nil {
		return fail(err)
	}
	if stat.Mode&syscall.S_IFMT != syscall.S_IFREG {
		return fail(fmt.Errorf("session lock is not a regular file: %s", path))
	}
	if err := file.Chmod(0o600); err != nil {
		return fail(err)
	}
	if err := syscall.Flock(fd, mode); err != nil {
		return fail(err)
	}
	if err := file.Truncate(0); err == nil {
		_, _ = file.WriteAt([]byte(fmt.Sprintf("%d\n", os.Getpid())), 0)
		_ = file.Sync()
	}
	return func() {
		_ = syscall.Flock(fd, syscall.LOCK_UN)
		_ = file.Close()
	}, nil
}

func journalPath(paths config.Paths) string {
	return filepath.Join(paths.DataDir, operationJournalName)
}

func writeJournal(paths config.Paths, journal operationJournal) error {
	if err := secureDir(paths.DataDir); err != nil {
		return err
	}
	data, err := json.MarshalIndent(journal, "", "  ")
	if err != nil {
		return err
	}
	data = append(data, '\n')
	target := journalPath(paths)
	if info, err := os.Lstat(target); err == nil {
		if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
			return fmt.Errorf("refusing unsafe session journal: %s", target)
		}
	} else if !errors.Is(err, fs.ErrNotExist) {
		return err
	}
	tmp, err := os.CreateTemp(paths.DataDir, ".sessions-operation-*.tmp")
	if err != nil {
		return err
	}
	name := tmp.Name()
	defer os.Remove(name)
	if err := tmp.Chmod(0o600); err != nil {
		_ = tmp.Close()
		return err
	}
	if _, err := tmp.Write(data); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Rename(name, target); err != nil {
		return err
	}
	if err := os.Chmod(target, 0o600); err != nil {
		return err
	}
	return syncDirectory(paths.DataDir)
}

func readJournal(paths config.Paths) (operationJournal, error) {
	path := journalPath(paths)
	info, err := os.Lstat(path)
	if err != nil {
		return operationJournal{}, err
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() || info.Size() > 1_048_576 {
		return operationJournal{}, fmt.Errorf("refusing unsafe session journal: %s", path)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return operationJournal{}, err
	}
	var journal operationJournal
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&journal); err != nil {
		return operationJournal{}, fmt.Errorf("parse session journal: %w", err)
	}
	var extra any
	if err := decoder.Decode(&extra); !errors.Is(err, io.EOF) {
		if err == nil {
			return operationJournal{}, errors.New("parse session journal: unexpected trailing data")
		}
		return operationJournal{}, fmt.Errorf("parse session journal: %w", err)
	}
	return journal, nil
}

func clearJournal(paths config.Paths) error {
	path := journalPath(paths)
	info, err := os.Lstat(path)
	if errors.Is(err, fs.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
		return fmt.Errorf("refusing unsafe session journal: %s", path)
	}
	if err := os.Remove(path); err != nil {
		return err
	}
	return syncDirectory(paths.DataDir)
}

func validateJournal(journal operationJournal, cfg config.Config) error {
	if journal.Version != 1 || (journal.Operation != "enable" && journal.Operation != "disable") {
		return errors.New("invalid session operation journal")
	}
	if !filepath.IsAbs(journal.Shared) || filepath.Clean(journal.Shared) == string(filepath.Separator) {
		return errors.New("session operation journal contains unsafe shared path")
	}
	validTargets := make(map[string]bool)
	for _, account := range cfg.Accounts {
		for _, name := range historyDirectoryNames {
			validTargets[filepath.Clean(filepath.Join(account.Home, name))] = true
		}
	}
	seenTargets := make(map[string]bool)
	for _, item := range journal.Items {
		target := filepath.Clean(item.Target)
		if item.Target != target || !filepath.IsAbs(target) || !validTargets[target] || seenTargets[target] {
			return fmt.Errorf("session operation journal contains unexpected target: %s", item.Target)
		}
		seenTargets[target] = true
		expectedShared := filepath.Clean(sharedHistoryDir(journal.Shared, filepath.Base(target)))
		if !filepath.IsAbs(item.Shared) || filepath.Clean(item.Shared) != expectedShared {
			return fmt.Errorf("session operation journal contains unexpected shared path: %s", item.Shared)
		}
		if item.Backup != "" && (journal.Operation != "enable" || filepath.Dir(item.Backup) != filepath.Dir(target) || !strings.HasPrefix(filepath.Base(item.Backup), filepath.Base(target)+".cab-backup-")) {
			return fmt.Errorf("session operation journal contains unexpected backup: %s", item.Backup)
		}
		if item.Stage != "" {
			parent := filepath.Dir(target)
			expectedPrefix := ".cab-" + filepath.Base(target) + "-disable-"
			if journal.Operation != "disable" || filepath.Dir(item.Stage) != parent || !strings.HasPrefix(filepath.Base(item.Stage), expectedPrefix) {
				return fmt.Errorf("session operation journal contains unexpected stage: %s", item.Stage)
			}
		}
		if journal.Operation == "enable" && item.Stage != "" {
			return fmt.Errorf("session enable journal contains a disable stage: %s", item.Stage)
		}
		if journal.Operation == "disable" && (item.Backup != "" || item.Stage == "") {
			return fmt.Errorf("session disable journal contains incomplete target: %s", item.Target)
		}
	}
	return nil
}

func rollbackEnableTargets(items []operationTarget) error {
	var result error
	for index := len(items) - 1; index >= 0; index-- {
		item := items[index]
		if info, err := os.Lstat(item.Target); err == nil {
			if info.Mode()&os.ModeSymlink != 0 && sameResolvedPath(item.Target, item.Shared) {
				if err := os.Remove(item.Target); err != nil {
					result = errors.Join(result, err)
					continue
				}
			} else if item.Backup != "" {
				if _, backupErr := os.Lstat(item.Backup); backupErr == nil {
					result = errors.Join(result, fmt.Errorf("cannot restore %s while unexpected target exists", item.Target))
					continue
				}
			} else {
				continue
			}
		} else if !errors.Is(err, fs.ErrNotExist) {
			result = errors.Join(result, err)
			continue
		}
		if item.Backup != "" {
			if _, err := os.Lstat(item.Backup); err == nil {
				result = errors.Join(result, os.Rename(item.Backup, item.Target))
			} else if !errors.Is(err, fs.ErrNotExist) {
				result = errors.Join(result, err)
			}
		}
	}
	return result
}

func rollbackEnableOperation(paths config.Paths, items []operationTarget) error {
	if err := rollbackEnableTargets(items); err != nil {
		return err
	}
	return clearJournal(paths)
}

func rollbackDisableTargets(items []operationTarget) error {
	var result error
	for index := len(items) - 1; index >= 0; index-- {
		item := items[index]
		info, err := os.Lstat(item.Target)
		if err == nil {
			if info.Mode()&os.ModeSymlink != 0 && sameResolvedPath(item.Target, item.Shared) {
				// Already restored.
			} else if info.IsDir() {
				if err := os.RemoveAll(item.Target); err != nil {
					result = errors.Join(result, err)
					continue
				}
				if err := os.Symlink(item.Shared, item.Target); err != nil {
					result = errors.Join(result, err)
				}
			} else {
				result = errors.Join(result, fmt.Errorf("unexpected disable target during rollback: %s", item.Target))
			}
		} else if errors.Is(err, fs.ErrNotExist) {
			if err := os.Symlink(item.Shared, item.Target); err != nil {
				result = errors.Join(result, err)
			}
		} else {
			result = errors.Join(result, err)
		}
		if item.Stage != "" {
			if err := os.RemoveAll(item.Stage); err != nil {
				result = errors.Join(result, err)
			}
		}
	}
	return result
}

func rollbackDisableOperation(paths config.Paths, items []operationTarget) error {
	if err := rollbackDisableTargets(items); err != nil {
		return err
	}
	return clearJournal(paths)
}

func cleanupOperationStages(items []operationTarget) {
	for _, item := range items {
		if item.Stage != "" {
			_ = os.RemoveAll(item.Stage)
		}
	}
}

func sameResolvedPath(left, right string) bool {
	resolvedLeft, err := filepath.EvalSymlinks(left)
	if err != nil {
		return false
	}
	resolvedRight, err := filepath.EvalSymlinks(right)
	if err != nil {
		return false
	}
	return filepath.Clean(resolvedLeft) == filepath.Clean(resolvedRight)
}

func syncDirectory(path string) error {
	directory, err := os.Open(path)
	if err != nil {
		return err
	}
	defer directory.Close()
	return directory.Sync()
}
