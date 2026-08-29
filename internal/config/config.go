package config

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"syscall"
)

const CurrentVersion = 1

var accountNamePattern = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$`)

func ValidateAccountName(name string) error {
	if !accountNamePattern.MatchString(name) {
		return fmt.Errorf("invalid account name %q", name)
	}
	return nil
}

type Account struct {
	Name string `json:"name"`
	Home string `json:"home"`
}

type Rotation struct {
	Enabled   bool     `json:"enabled"`
	Accounts  []string `json:"accounts,omitempty"`
	NextIndex int      `json:"next_index,omitempty"`
}

type Config struct {
	Version           int       `json:"version"`
	DefaultAccount    string    `json:"default_account,omitempty"`
	RemoteAccount     string    `json:"remote_account,omitempty"`
	SharedSessionsDir string    `json:"shared_sessions_dir,omitempty"`
	Rotation          Rotation  `json:"rotation,omitempty"`
	Accounts          []Account `json:"accounts"`
}

type Paths struct {
	ConfigDir string
	DataDir   string
	File      string
}

// Mutation describes reversible side effects performed while a configuration
// update is locked. Rollback is called when validation or persistence fails;
// Commit is called after the new configuration has been durably saved.
type Mutation struct {
	Rollback func() error
	Commit   func() error
}

func DefaultPaths() (Paths, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return Paths{}, fmt.Errorf("resolve home directory: %w", err)
	}
	configDir := os.Getenv("CAB_CONFIG_HOME")
	if configDir == "" {
		base := os.Getenv("XDG_CONFIG_HOME")
		if base == "" {
			base = filepath.Join(home, ".config")
		}
		configDir = filepath.Join(base, "codex-account-bridge")
	}
	dataDir := os.Getenv("CAB_DATA_HOME")
	if dataDir == "" {
		base := os.Getenv("XDG_DATA_HOME")
		if base == "" {
			base = filepath.Join(home, ".local", "share")
		}
		dataDir = filepath.Join(base, "codex-account-bridge")
	}
	configDir, err = filepath.Abs(configDir)
	if err != nil {
		return Paths{}, err
	}
	dataDir, err = filepath.Abs(dataDir)
	if err != nil {
		return Paths{}, err
	}
	configDir = filepath.Clean(configDir)
	dataDir = filepath.Clean(dataDir)
	if configDir == string(filepath.Separator) || dataDir == string(filepath.Separator) {
		return Paths{}, errors.New("CAB config and data directories cannot be filesystem root")
	}
	if PathsOverlap(configDir, dataDir) {
		return Paths{}, fmt.Errorf("CAB config and data directories cannot overlap: %s and %s", configDir, dataDir)
	}
	return Paths{ConfigDir: configDir, DataDir: dataDir, File: filepath.Join(configDir, "config.json")}, nil
}

func DefaultCodexHome() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("resolve home directory: %w", err)
	}
	return filepath.Abs(filepath.Join(home, ".codex"))
}

func Empty() Config {
	return Config{Version: CurrentVersion, Accounts: []Account{}}
}

func Load(paths Paths) (Config, error) {
	info, err := os.Lstat(paths.File)
	if errors.Is(err, fs.ErrNotExist) {
		return Empty(), nil
	}
	if err != nil {
		return Config{}, fmt.Errorf("inspect config: %w", err)
	}
	if info.Mode()&os.ModeSymlink != 0 {
		return Config{}, fmt.Errorf("refusing symlink config: %s", paths.File)
	}
	if !info.Mode().IsRegular() {
		return Config{}, fmt.Errorf("config is not a regular file: %s", paths.File)
	}
	if info.Mode().Perm()&0o077 != 0 {
		return Config{}, fmt.Errorf("config permissions are too broad (%04o); run chmod 600 %s", info.Mode().Perm(), paths.File)
	}
	data, err := os.ReadFile(paths.File)
	if err != nil {
		return Config{}, fmt.Errorf("read config: %w", err)
	}
	if err := rejectDuplicateJSONKeys(data); err != nil {
		return Config{}, fmt.Errorf("parse config: %w", err)
	}
	var cfg Config
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&cfg); err != nil {
		return Config{}, fmt.Errorf("parse config: %w", err)
	}
	if err := ensureJSONEOF(decoder); err != nil {
		return Config{}, fmt.Errorf("parse config: %w", err)
	}
	if err := cfg.Validate(); err != nil {
		return Config{}, err
	}
	if err := cfg.validateForPaths(paths); err != nil {
		return Config{}, err
	}
	return cfg, nil
}

func rejectDuplicateJSONKeys(data []byte) error {
	decoder := json.NewDecoder(bytes.NewReader(data))
	var consume func() error
	consume = func() error {
		token, err := decoder.Token()
		if err != nil {
			return err
		}
		delim, ok := token.(json.Delim)
		if !ok {
			return nil
		}
		switch delim {
		case '{':
			seen := make(map[string]bool)
			for decoder.More() {
				keyToken, err := decoder.Token()
				if err != nil {
					return err
				}
				key, ok := keyToken.(string)
				if !ok {
					return errors.New("object key is not a string")
				}
				if seen[key] {
					return fmt.Errorf("duplicate JSON key %q", key)
				}
				seen[key] = true
				if err := consume(); err != nil {
					return err
				}
			}
			_, err = decoder.Token()
			return err
		case '[':
			for decoder.More() {
				if err := consume(); err != nil {
					return err
				}
			}
			_, err = decoder.Token()
			return err
		default:
			return fmt.Errorf("unexpected JSON delimiter %q", delim)
		}
	}
	if err := consume(); err != nil {
		return err
	}
	return ensureJSONEOF(decoder)
}

func ensureJSONEOF(decoder *json.Decoder) error {
	var extra any
	if err := decoder.Decode(&extra); errors.Is(err, io.EOF) {
		return nil
	} else if err != nil {
		return err
	}
	return errors.New("unexpected data after configuration object")
}

func Save(paths Paths, cfg Config) error {
	if err := cfg.Validate(); err != nil {
		return err
	}
	if err := cfg.validateForPaths(paths); err != nil {
		return err
	}
	if err := secureDir(paths.ConfigDir); err != nil {
		return err
	}
	exists := false
	if info, err := os.Lstat(paths.File); err == nil {
		if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
			return fmt.Errorf("refusing to replace unsafe config: %s", paths.File)
		}
		exists = true
	} else if !errors.Is(err, fs.ErrNotExist) {
		return err
	}
	data, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return err
	}
	data = append(data, '\n')
	if exists {
		previous, err := os.ReadFile(paths.File)
		if err != nil {
			return err
		}
		if err := writeAtomic(paths.ConfigDir, paths.File+".backup", previous); err != nil {
			return fmt.Errorf("write config backup: %w", err)
		}
	}
	return writeAtomic(paths.ConfigDir, paths.File, data)
}

func writeAtomic(dir, target string, data []byte) error {
	if info, err := os.Lstat(target); err == nil {
		if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
			return fmt.Errorf("refusing unsafe target: %s", target)
		}
	} else if !errors.Is(err, fs.ErrNotExist) {
		return err
	}
	tmp, err := os.CreateTemp(dir, ".config-*.tmp")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName)
	if err := tmp.Chmod(0o600); err != nil {
		tmp.Close()
		return err
	}
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Rename(tmpName, target); err != nil {
		return err
	}
	if err := os.Chmod(target, 0o600); err != nil {
		return err
	}
	return syncDirectory(dir)
}

func syncDirectory(path string) error {
	directory, err := os.Open(path)
	if err != nil {
		return err
	}
	defer directory.Close()
	return directory.Sync()
}

func secureDir(path string) error {
	if !filepath.IsAbs(path) || filepath.Clean(path) == string(filepath.Separator) {
		return fmt.Errorf("refusing unsafe directory: %s", path)
	}
	if info, err := os.Lstat(path); err == nil {
		if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
			return fmt.Errorf("refusing unsafe directory: %s", path)
		}
		return os.Chmod(path, 0o700)
	} else if !errors.Is(err, fs.ErrNotExist) {
		return err
	}
	if err := os.MkdirAll(path, 0o700); err != nil {
		return err
	}
	return os.Chmod(path, 0o700)
}

func EnsureDataDir(paths Paths) error   { return secureDir(paths.DataDir) }
func EnsureConfigDir(paths Paths) error { return secureDir(paths.ConfigDir) }

// Update serializes every configuration mutation, reloads the latest state
// after acquiring the lock, and rolls back any associated filesystem changes
// if validation or persistence fails.
func Update(paths Paths, mutate func(*Config) (Mutation, error)) (Config, error) {
	if err := EnsureConfigDir(paths); err != nil {
		return Config{}, err
	}
	unlock, err := fileLock(filepath.Join(paths.ConfigDir, "config.lock"))
	if err != nil {
		return Config{}, err
	}
	defer unlock()

	latest, err := Load(paths)
	if err != nil {
		return Config{}, err
	}
	mutation, err := mutate(&latest)
	if err != nil {
		if mutation.Rollback != nil {
			if rollbackErr := mutation.Rollback(); rollbackErr != nil {
				return Config{}, fmt.Errorf("%w; rollback failed: %v", err, rollbackErr)
			}
		}
		return Config{}, err
	}
	rollback := func(cause error) (Config, error) {
		if mutation.Rollback != nil {
			if rollbackErr := mutation.Rollback(); rollbackErr != nil {
				return Config{}, fmt.Errorf("%w; rollback failed: %v", cause, rollbackErr)
			}
		}
		return Config{}, cause
	}
	if err := latest.Validate(); err != nil {
		return rollback(err)
	}
	if err := Save(paths, latest); err != nil {
		return rollback(err)
	}
	if mutation.Commit != nil {
		if err := mutation.Commit(); err != nil {
			return Config{}, fmt.Errorf("configuration saved but transaction cleanup failed: %w", err)
		}
	}
	return latest, nil
}

func UpdateSimple(paths Paths, mutate func(*Config) error) (Config, error) {
	return Update(paths, func(cfg *Config) (Mutation, error) {
		return Mutation{}, mutate(cfg)
	})
}

// ReadLocked gives recovery and diagnostic code a stable view that cannot race
// a concurrent configuration writer.
func ReadLocked(paths Paths, inspect func(Config) error) (Config, error) {
	if err := EnsureConfigDir(paths); err != nil {
		return Config{}, err
	}
	unlock, err := fileLock(filepath.Join(paths.ConfigDir, "config.lock"))
	if err != nil {
		return Config{}, err
	}
	defer unlock()
	cfg, err := Load(paths)
	if err != nil {
		return Config{}, err
	}
	if err := inspect(cfg); err != nil {
		return Config{}, err
	}
	return cfg, nil
}

func fileLock(path string) (func(), error) {
	if info, err := os.Lstat(path); err == nil {
		if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
			return nil, fmt.Errorf("refusing unsafe lock file: %s", path)
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
		return fail(fmt.Errorf("lock is not a regular file: %s", path))
	}
	if err := file.Chmod(0o600); err != nil {
		return fail(err)
	}
	if err := syscall.Flock(fd, syscall.LOCK_EX); err != nil {
		return fail(err)
	}
	return func() {
		_ = syscall.Flock(fd, syscall.LOCK_UN)
		_ = file.Close()
	}, nil
}

func (cfg Config) Validate() error {
	if cfg.Version != CurrentVersion {
		return fmt.Errorf("unsupported config version %d", cfg.Version)
	}
	names := make(map[string]bool)
	homes := make(map[string]bool)
	for _, account := range cfg.Accounts {
		if err := ValidateAccountName(account.Name); err != nil {
			return err
		}
		key := strings.ToLower(account.Name)
		if names[key] {
			return fmt.Errorf("duplicate account name %q", account.Name)
		}
		names[key] = true
		if !filepath.IsAbs(account.Home) {
			return fmt.Errorf("account home must be absolute: %s", account.Home)
		}
		home := filepath.Clean(account.Home)
		if home == string(filepath.Separator) {
			return fmt.Errorf("account home cannot be filesystem root")
		}
		if homes[home] {
			return fmt.Errorf("duplicate account home %s", home)
		}
		homes[home] = true
	}
	cleanHomes := make([]string, 0, len(homes))
	for home := range homes {
		cleanHomes = append(cleanHomes, home)
	}
	for left := 0; left < len(cleanHomes); left++ {
		for right := left + 1; right < len(cleanHomes); right++ {
			if PathsOverlap(cleanHomes[left], cleanHomes[right]) {
				return fmt.Errorf("account homes cannot contain one another: %s and %s", cleanHomes[left], cleanHomes[right])
			}
		}
	}
	if cfg.SharedSessionsDir != "" {
		if !filepath.IsAbs(cfg.SharedSessionsDir) {
			return fmt.Errorf("shared sessions directory must be absolute: %s", cfg.SharedSessionsDir)
		}
		shared := filepath.Clean(cfg.SharedSessionsDir)
		if shared == string(filepath.Separator) {
			return errors.New("shared sessions directory cannot be filesystem root")
		}
		for _, home := range cleanHomes {
			if PathsOverlap(shared, home) {
				return fmt.Errorf("shared sessions directory overlaps account home: %s and %s", shared, home)
			}
		}
	}
	for _, selected := range []string{cfg.DefaultAccount, cfg.RemoteAccount} {
		if selected != "" && !names[strings.ToLower(selected)] {
			return fmt.Errorf("selected account %q is not configured", selected)
		}
	}
	rotationNames := make(map[string]bool)
	for _, selected := range cfg.Rotation.Accounts {
		key := strings.ToLower(selected)
		if !names[key] {
			return fmt.Errorf("rotation account %q is not configured", selected)
		}
		if rotationNames[key] {
			return fmt.Errorf("duplicate rotation account %q", selected)
		}
		rotationNames[key] = true
	}
	if cfg.Rotation.Enabled && len(cfg.Rotation.Accounts) < 2 {
		return errors.New("rotation requires at least two configured accounts")
	}
	if len(cfg.Rotation.Accounts) == 0 {
		if cfg.Rotation.NextIndex != 0 {
			return errors.New("rotation next index must be zero when no accounts are configured")
		}
	} else if cfg.Rotation.NextIndex < 0 || cfg.Rotation.NextIndex >= len(cfg.Rotation.Accounts) {
		return fmt.Errorf("rotation next index %d is out of range", cfg.Rotation.NextIndex)
	}
	return nil
}

// PathsOverlap reports lexical containment in either direction. Callers that
// operate on existing paths must additionally reject final-component symlinks.
func PathsOverlap(left, right string) bool {
	within := func(parent, child string) bool {
		relative, err := filepath.Rel(parent, child)
		return err == nil && relative != "." && relative != ".." && !strings.HasPrefix(relative, ".."+string(filepath.Separator))
	}
	return filepath.Clean(left) == filepath.Clean(right) || within(left, right) || within(right, left)
}

func (cfg Config) validateForPaths(paths Paths) error {
	for _, account := range cfg.Accounts {
		if PathsOverlap(account.Home, paths.ConfigDir) {
			return fmt.Errorf("account home overlaps CAB config directory: %s and %s", account.Home, paths.ConfigDir)
		}
		if info, err := os.Lstat(account.Home); err == nil {
			if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
				return fmt.Errorf("account home is not a safe directory: %s", account.Home)
			}
		} else if !errors.Is(err, fs.ErrNotExist) {
			return fmt.Errorf("inspect account home %s: %w", account.Home, err)
		}
	}
	if cfg.SharedSessionsDir != "" && PathsOverlap(cfg.SharedSessionsDir, paths.ConfigDir) {
		return fmt.Errorf("shared sessions directory overlaps CAB config directory: %s and %s", cfg.SharedSessionsDir, paths.ConfigDir)
	}
	if cfg.SharedSessionsDir != "" {
		if info, err := os.Lstat(cfg.SharedSessionsDir); err == nil {
			if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
				return fmt.Errorf("shared sessions path is not a safe directory: %s", cfg.SharedSessionsDir)
			}
		} else if !errors.Is(err, fs.ErrNotExist) {
			return fmt.Errorf("inspect shared sessions directory %s: %w", cfg.SharedSessionsDir, err)
		}
	}
	return nil
}

func (cfg Config) Find(name string) (Account, bool) {
	for _, account := range cfg.Accounts {
		if strings.EqualFold(account.Name, name) {
			return account, true
		}
	}
	return Account{}, false
}

func (cfg *Config) Add(account Account) error {
	if _, ok := cfg.Find(account.Name); ok {
		return fmt.Errorf("account %q already exists", account.Name)
	}
	cfg.Accounts = append(cfg.Accounts, account)
	sort.Slice(cfg.Accounts, func(i, j int) bool { return cfg.Accounts[i].Name < cfg.Accounts[j].Name })
	if cfg.DefaultAccount == "" {
		cfg.DefaultAccount = account.Name
	}
	return cfg.Validate()
}

func (cfg *Config) Remove(name string) {
	next := cfg.Accounts[:0]
	for _, account := range cfg.Accounts {
		if !strings.EqualFold(account.Name, name) {
			next = append(next, account)
		}
	}
	cfg.Accounts = next
	rotation := cfg.Rotation.Accounts[:0]
	for _, selected := range cfg.Rotation.Accounts {
		if !strings.EqualFold(selected, name) {
			rotation = append(rotation, selected)
		}
	}
	cfg.Rotation.Accounts = rotation
	if len(rotation) < 2 {
		cfg.Rotation.Enabled = false
	}
	if len(rotation) == 0 || cfg.Rotation.NextIndex >= len(rotation) {
		cfg.Rotation.NextIndex = 0
	}
}

func (cfg *Config) SetRotationAccounts(names []string) error {
	canonical := make([]string, 0, len(names))
	seen := make(map[string]bool)
	for _, name := range names {
		account, ok := cfg.Find(name)
		if !ok {
			return fmt.Errorf("unknown account %q", name)
		}
		key := strings.ToLower(account.Name)
		if seen[key] {
			return fmt.Errorf("duplicate rotation account %q", account.Name)
		}
		seen[key] = true
		canonical = append(canonical, account.Name)
	}
	cfg.Rotation.Accounts = canonical
	cfg.Rotation.NextIndex = 0
	if len(canonical) < 2 {
		cfg.Rotation.Enabled = false
	}
	return cfg.Validate()
}

func (cfg *Config) NextRotationAccount() (Account, error) {
	if !cfg.Rotation.Enabled {
		return Account{}, errors.New("rotation is disabled")
	}
	if len(cfg.Rotation.Accounts) < 2 {
		return Account{}, errors.New("rotation requires at least two configured accounts")
	}
	name := cfg.Rotation.Accounts[cfg.Rotation.NextIndex]
	account, ok := cfg.Find(name)
	if !ok {
		return Account{}, fmt.Errorf("rotation account %q is not configured", name)
	}
	cfg.Rotation.NextIndex = (cfg.Rotation.NextIndex + 1) % len(cfg.Rotation.Accounts)
	return account, nil
}

func ExpandPath(value string) (string, error) {
	if value == "" {
		return "", errors.New("path is empty")
	}
	if value == "~" || strings.HasPrefix(value, "~/") {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", err
		}
		value = filepath.Join(home, strings.TrimPrefix(value, "~/"))
	}
	abs, err := filepath.Abs(value)
	if err != nil {
		return "", err
	}
	return filepath.Clean(abs), nil
}
