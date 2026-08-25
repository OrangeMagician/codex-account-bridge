package config

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

const CurrentVersion = 1

var accountNamePattern = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$`)

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
	var cfg Config
	if err := json.Unmarshal(data, &cfg); err != nil {
		return Config{}, fmt.Errorf("parse config: %w", err)
	}
	if err := cfg.Validate(); err != nil {
		return Config{}, err
	}
	return cfg, nil
}

func Save(paths Paths, cfg Config) error {
	if err := cfg.Validate(); err != nil {
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
	return os.Chmod(target, 0o600)
}

func secureDir(path string) error {
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

func (cfg Config) Validate() error {
	if cfg.Version != CurrentVersion {
		return fmt.Errorf("unsupported config version %d", cfg.Version)
	}
	names := make(map[string]bool)
	homes := make(map[string]bool)
	for _, account := range cfg.Accounts {
		if !accountNamePattern.MatchString(account.Name) {
			return fmt.Errorf("invalid account name %q", account.Name)
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
	return filepath.Abs(value)
}
