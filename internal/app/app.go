package app

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"time"

	"github.com/OrangeMagician/codex-account-bridge/internal/codex"
	"github.com/OrangeMagician/codex-account-bridge/internal/config"
	"github.com/OrangeMagician/codex-account-bridge/internal/session"
)

func Run(argv []string, version string) (int, error) {
	if len(argv) == 0 {
		return 2, errors.New("missing argv[0]")
	}
	paths, err := config.DefaultPaths()
	if err != nil {
		return 1, err
	}
	if filepath.Base(argv[0]) == "codex" {
		cfg, err := config.Load(paths)
		if err != nil {
			return 1, err
		}
		account, err := selectedAccount(cfg, cfg.RemoteAccount)
		if err != nil {
			return 2, fmt.Errorf("remote shim: %w", err)
		}
		return codex.Run(account.Home, argv[1:])
	}
	if len(argv) < 2 {
		usage()
		return 2, nil
	}
	command := argv[1]
	args := argv[2:]
	if command == "help" || command == "--help" || command == "-h" {
		usage()
		return 0, nil
	}
	if command == "version" || command == "--version" {
		fmt.Printf("cab %s\n", version)
		return 0, nil
	}
	if command == "init" {
		cfg, err := config.Load(paths)
		if err != nil {
			return 1, err
		}
		if err := config.EnsureDataDir(paths); err != nil {
			return 1, err
		}
		if err := config.Save(paths, cfg); err != nil {
			return 1, err
		}
		fmt.Printf("initialized %s\n", paths.File)
		return 0, nil
	}
	cfg, err := config.Load(paths)
	if err != nil {
		return 1, err
	}
	switch command {
	case "account":
		return accountCommand(paths, &cfg, args)
	case "use":
		return useCommand(paths, &cfg, args, false)
	case "remote":
		return remoteCommand(paths, &cfg, args)
	case "login":
		return loginCommand(cfg, args)
	case "run":
		return runCommand(paths, cfg, args, false)
	case "app-server":
		return runCommand(paths, cfg, args, true)
	case "rotation":
		return rotationCommand(paths, &cfg, args)
	case "status":
		return statusCommand(cfg, args)
	case "sessions":
		return sessionsCommand(paths, &cfg, args)
	case "shim":
		return shimCommand(paths, args)
	case "doctor":
		return doctor(paths, cfg)
	default:
		return 2, fmt.Errorf("unknown command %q; run cab help", command)
	}
}

func usage() {
	fmt.Print(`codex-account-bridge (cab)

Secure, explicit account selection for the official Codex CLI.

Commands:
  cab init
  cab account add [--home PATH] NAME
  cab account import-current NAME
  cab account list
  cab account remove NAME
  cab use NAME
  cab login [--device-auth|--browser-auth] NAME
  cab run [--account NAME] -- [codex arguments]
  cab app-server [--account NAME] -- [app-server arguments]
  cab status [--json]
  cab rotation status [--json]
  cab rotation configure --accounts NAME,NAME
  cab rotation enable|disable|reset
  cab remote use NAME
  cab sessions enable --acknowledge-cross-account-context --confirm-codex-stopped
  cab sessions disable --confirm-codex-stopped
  cab shim install [--dir PATH] [--force]
  cab shim remove [--dir PATH]
  cab doctor
  cab version

Safety defaults: launch rotation is opt-in and never reacts to quota/errors;
no proxy, auth copying, automatic project trust, or approval/sandbox bypass.
`)
}

func accountCommand(paths config.Paths, cfg *config.Config, args []string) (int, error) {
	if len(args) == 0 {
		return 2, errors.New("account requires add, import-current, list, or remove")
	}
	switch args[0] {
	case "list":
		if len(args) != 1 {
			return 2, errors.New("account list takes no arguments")
		}
		if len(cfg.Accounts) == 0 {
			fmt.Println("No accounts configured.")
			return 0, nil
		}
		fmt.Println("NAME\tDEFAULT\tREMOTE\tLOGIN\tHOME")
		for _, account := range cfg.Accounts {
			fmt.Printf("%s\t%s\t%s\t%s\t%s\n", account.Name, marker(cfg.DefaultAccount, account.Name), marker(cfg.RemoteAccount, account.Name), authStatus(account.Home), account.Home)
		}
		return 0, nil
	case "add":
		flags := newFlags("account add")
		homeFlag := flags.String("home", "", "existing or new CODEX_HOME")
		if err := flags.Parse(args[1:]); err != nil {
			return 2, err
		}
		if flags.NArg() != 1 {
			return 2, errors.New("usage: cab account add [--home PATH] NAME")
		}
		name := flags.Arg(0)
		home := *homeFlag
		if home == "" {
			home = filepath.Join(paths.DataDir, "accounts", name)
		}
		home, err := config.ExpandPath(home)
		if err != nil {
			return 1, err
		}
		if err := ensureAccountHome(home); err != nil {
			return 1, err
		}
		if err := cfg.Add(config.Account{Name: name, Home: home}); err != nil {
			return 2, err
		}
		if err := config.Save(paths, *cfg); err != nil {
			return 1, err
		}
		fmt.Printf("added %s at %s\n", name, home)
		fmt.Printf("next: cab login %s\n", name)
		return 0, nil
	case "import-current":
		if len(args) != 2 {
			return 2, errors.New("usage: cab account import-current NAME")
		}
		home, err := config.DefaultCodexHome()
		if err != nil {
			return 1, err
		}
		for _, account := range cfg.Accounts {
			if filepath.Clean(account.Home) == filepath.Clean(home) {
				return 2, fmt.Errorf("current Codex home is already registered as %q", account.Name)
			}
		}
		loggedIn, err := codex.LoggedIn(home)
		if err != nil {
			return 1, fmt.Errorf("check current Codex login: %w", err)
		}
		if !loggedIn {
			return 2, errors.New("the default Codex home is not logged in")
		}
		if err := ensureAccountHome(home); err != nil {
			return 1, err
		}
		if err := cfg.Add(config.Account{Name: args[1], Home: home}); err != nil {
			return 2, err
		}
		if err := config.Save(paths, *cfg); err != nil {
			return 1, err
		}
		fmt.Printf("registered existing Codex login as %s; credentials were not copied\n", args[1])
		return 0, nil
	case "remove":
		if len(args) != 2 {
			return 2, errors.New("usage: cab account remove NAME")
		}
		if cfg.SharedSessionsDir != "" {
			return 2, errors.New("disable session sharing before removing an account")
		}
		name := args[1]
		if _, ok := cfg.Find(name); !ok {
			return 2, fmt.Errorf("unknown account %q", name)
		}
		cfg.Remove(name)
		if strings.EqualFold(cfg.DefaultAccount, name) {
			cfg.DefaultAccount = ""
			if len(cfg.Accounts) > 0 {
				cfg.DefaultAccount = cfg.Accounts[0].Name
			}
		}
		if strings.EqualFold(cfg.RemoteAccount, name) {
			cfg.RemoteAccount = ""
		}
		if err := config.Save(paths, *cfg); err != nil {
			return 1, err
		}
		fmt.Printf("removed %s from config; files were preserved\n", name)
		return 0, nil
	default:
		return 2, fmt.Errorf("unknown account command %q", args[0])
	}
}

func useCommand(paths config.Paths, cfg *config.Config, args []string, remote bool) (int, error) {
	if len(args) != 1 {
		return 2, errors.New("account name required")
	}
	account, ok := cfg.Find(args[0])
	if !ok {
		return 2, fmt.Errorf("unknown account %q", args[0])
	}
	if remote {
		cfg.RemoteAccount = account.Name
	} else {
		cfg.DefaultAccount = account.Name
	}
	if err := config.Save(paths, *cfg); err != nil {
		return 1, err
	}
	if remote {
		fmt.Printf("remote app-server account: %s\n", account.Name)
	} else {
		fmt.Printf("default account: %s\n", account.Name)
	}
	return 0, nil
}

func remoteCommand(paths config.Paths, cfg *config.Config, args []string) (int, error) {
	if len(args) == 2 && args[0] == "use" {
		return useCommand(paths, cfg, args[1:], true)
	}
	return 2, errors.New("usage: cab remote use NAME")
}

func loginCommand(cfg config.Config, args []string) (int, error) {
	flags := newFlags("login")
	device := flags.Bool("device-auth", false, "use the official headless device login")
	browser := flags.Bool("browser-auth", false, "return the official browser OAuth URL without opening the default browser")
	if err := flags.Parse(args); err != nil {
		return 2, err
	}
	if flags.NArg() != 1 || (*device && *browser) {
		return 2, errors.New("usage: cab login [--device-auth|--browser-auth] NAME")
	}
	account, ok := cfg.Find(flags.Arg(0))
	if !ok {
		return 2, fmt.Errorf("unknown account %q", flags.Arg(0))
	}
	loginArgs := []string{"login"}
	if *device {
		loginArgs = append(loginArgs, "--device-auth")
	}
	if *browser {
		return codex.RunBrowserLogin(account.Home)
	}
	return codex.Run(account.Home, loginArgs)
}

func runCommand(paths config.Paths, cfg config.Config, args []string, appServer bool) (int, error) {
	flags := newFlags("run")
	accountName := flags.String("account", "", "configured account name")
	if err := flags.Parse(args); err != nil {
		return 2, err
	}
	var account config.Account
	var err error
	if *accountName == "" && !appServer && cfg.Rotation.Enabled {
		account, err = takeNextRotationAccount(paths)
		if err == nil {
			fmt.Printf("rotation selected account: %s\n", account.Name)
		}
	} else {
		account, err = selectedAccount(cfg, firstNonEmpty(*accountName, cfg.DefaultAccount))
	}
	if err != nil {
		return 2, err
	}
	commandArgs := flags.Args()
	if appServer {
		commandArgs = append([]string{"app-server"}, commandArgs...)
	}
	return codex.Run(account.Home, commandArgs)
}

func rotationCommand(paths config.Paths, cfg *config.Config, args []string) (int, error) {
	if len(args) == 0 {
		return 2, errors.New("rotation requires status, configure, enable, disable, or reset")
	}
	switch args[0] {
	case "status":
		flags := newFlags("rotation status")
		jsonOutput := flags.Bool("json", false, "print machine-readable JSON")
		if err := flags.Parse(args[1:]); err != nil || flags.NArg() != 0 {
			return 2, errors.New("usage: cab rotation status [--json]")
		}
		if *jsonOutput {
			return printJSON(cfg.Rotation)
		}
		state := "disabled"
		if cfg.Rotation.Enabled {
			state = "enabled"
		}
		next := "-"
		if len(cfg.Rotation.Accounts) > 0 {
			next = cfg.Rotation.Accounts[cfg.Rotation.NextIndex]
		}
		fmt.Printf("rotation: %s\naccounts: %s\nnext: %s\n", state, strings.Join(cfg.Rotation.Accounts, ", "), next)
		return 0, nil
	case "configure":
		flags := newFlags("rotation configure")
		accounts := flags.String("accounts", "", "comma-separated account names in launch order")
		if err := flags.Parse(args[1:]); err != nil {
			return 2, err
		}
		if flags.NArg() != 0 || strings.TrimSpace(*accounts) == "" {
			return 2, errors.New("usage: cab rotation configure --accounts NAME,NAME")
		}
		names := splitAccountNames(*accounts)
		if err := cfg.SetRotationAccounts(names); err != nil {
			return 2, err
		}
		if err := config.Save(paths, *cfg); err != nil {
			return 1, err
		}
		fmt.Printf("rotation order: %s\n", strings.Join(cfg.Rotation.Accounts, ", "))
		return 0, nil
	case "enable":
		if len(args) != 1 {
			return 2, errors.New("usage: cab rotation enable")
		}
		if len(cfg.Rotation.Accounts) < 2 {
			return 2, errors.New("configure at least two rotation accounts first")
		}
		cfg.Rotation.Enabled = true
		if err := config.Save(paths, *cfg); err != nil {
			return 1, err
		}
		fmt.Println("launch rotation enabled; quota and errors never trigger switching")
		return 0, nil
	case "disable":
		if len(args) != 1 {
			return 2, errors.New("usage: cab rotation disable")
		}
		cfg.Rotation.Enabled = false
		if err := config.Save(paths, *cfg); err != nil {
			return 1, err
		}
		fmt.Println("launch rotation disabled")
		return 0, nil
	case "reset":
		if len(args) != 1 {
			return 2, errors.New("usage: cab rotation reset")
		}
		cfg.Rotation.NextIndex = 0
		if err := config.Save(paths, *cfg); err != nil {
			return 1, err
		}
		fmt.Println("rotation reset to the first configured account")
		return 0, nil
	default:
		return 2, fmt.Errorf("unknown rotation command %q", args[0])
	}
}

type statusAccount struct {
	Name    string `json:"name"`
	Home    string `json:"home"`
	Login   string `json:"login"`
	Default bool   `json:"default"`
	Remote  bool   `json:"remote"`
}

type statusOutput struct {
	DefaultAccount string          `json:"default_account,omitempty"`
	RemoteAccount  string          `json:"remote_account,omitempty"`
	SharedSessions bool            `json:"shared_sessions"`
	Rotation       config.Rotation `json:"rotation"`
	CurrentLogin   currentLogin    `json:"current_login"`
	Accounts       []statusAccount `json:"accounts"`
}

type currentLogin struct {
	Home         string `json:"home"`
	Login        string `json:"login"`
	RegisteredAs string `json:"registered_as,omitempty"`
}

func statusCommand(cfg config.Config, args []string) (int, error) {
	flags := newFlags("status")
	jsonOutput := flags.Bool("json", false, "print machine-readable JSON")
	if err := flags.Parse(args); err != nil {
		return 2, err
	}
	if flags.NArg() != 0 {
		return 2, errors.New("usage: cab status [--json]")
	}
	status := statusOutput{DefaultAccount: cfg.DefaultAccount, RemoteAccount: cfg.RemoteAccount, SharedSessions: cfg.SharedSessionsDir != "", Rotation: cfg.Rotation, Accounts: make([]statusAccount, 0, len(cfg.Accounts))}
	for _, account := range cfg.Accounts {
		status.Accounts = append(status.Accounts, statusAccount{Name: account.Name, Home: account.Home, Login: authStatus(account.Home), Default: strings.EqualFold(cfg.DefaultAccount, account.Name), Remote: strings.EqualFold(cfg.RemoteAccount, account.Name)})
	}
	if home, err := config.DefaultCodexHome(); err == nil {
		status.CurrentLogin.Home = home
		status.CurrentLogin.Login = "missing"
		if loggedIn, loginErr := codex.LoggedIn(home); loginErr == nil && loggedIn {
			status.CurrentLogin.Login = "present"
		} else if loginErr != nil {
			status.CurrentLogin.Login = "unknown"
		}
		for _, account := range cfg.Accounts {
			if filepath.Clean(account.Home) == filepath.Clean(home) {
				status.CurrentLogin.RegisteredAs = account.Name
				break
			}
		}
	}
	if *jsonOutput {
		return printJSON(status)
	}
	fmt.Printf("default: %s\nremote: %s\nsession sharing: %t\nrotation: %t\n", cfg.DefaultAccount, cfg.RemoteAccount, status.SharedSessions, cfg.Rotation.Enabled)
	return 0, nil
}

func takeNextRotationAccount(paths config.Paths) (config.Account, error) {
	if err := config.EnsureConfigDir(paths); err != nil {
		return config.Account{}, err
	}
	lockPath := filepath.Join(paths.ConfigDir, "rotation.lock")
	if info, err := os.Lstat(lockPath); err == nil && (info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular()) {
		return config.Account{}, fmt.Errorf("refusing unsafe rotation lock: %s", lockPath)
	} else if err != nil && !errors.Is(err, fs.ErrNotExist) {
		return config.Account{}, err
	}
	fd, err := syscall.Open(lockPath, syscall.O_CREAT|syscall.O_RDWR|syscall.O_NOFOLLOW, 0o600)
	if err != nil {
		return config.Account{}, err
	}
	lock := os.NewFile(uintptr(fd), lockPath)
	defer lock.Close()
	var stat syscall.Stat_t
	if err := syscall.Fstat(fd, &stat); err != nil {
		return config.Account{}, err
	}
	if stat.Mode&syscall.S_IFMT != syscall.S_IFREG {
		return config.Account{}, fmt.Errorf("rotation lock is not a regular file: %s", lockPath)
	}
	if err := lock.Chmod(0o600); err != nil {
		return config.Account{}, err
	}
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX); err != nil {
		return config.Account{}, err
	}
	defer syscall.Flock(int(lock.Fd()), syscall.LOCK_UN)
	latest, err := config.Load(paths)
	if err != nil {
		return config.Account{}, err
	}
	account, err := latest.NextRotationAccount()
	if err != nil {
		return config.Account{}, err
	}
	if err := config.Save(paths, latest); err != nil {
		return config.Account{}, err
	}
	return account, nil
}

func splitAccountNames(value string) []string {
	parts := strings.Split(value, ",")
	result := make([]string, 0, len(parts))
	for _, part := range parts {
		if name := strings.TrimSpace(part); name != "" {
			result = append(result, name)
		}
	}
	return result
}

func printJSON(value any) (int, error) {
	data, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return 1, err
	}
	fmt.Println(string(data))
	return 0, nil
}

func sessionsCommand(paths config.Paths, cfg *config.Config, args []string) (int, error) {
	if len(args) == 0 {
		return 2, errors.New("sessions requires enable or disable")
	}
	flags := newFlags("sessions " + args[0])
	stopped := flags.Bool("confirm-codex-stopped", false, "confirm all affected Codex processes are stopped")
	ack := flags.Bool("acknowledge-cross-account-context", false, "acknowledge that another account can read resumed context")
	if err := flags.Parse(args[1:]); err != nil {
		return 2, err
	}
	if flags.NArg() != 0 || !*stopped {
		return 2, errors.New("--confirm-codex-stopped is required")
	}
	if len(cfg.Accounts) < 2 && args[0] == "enable" {
		return 2, errors.New("configure at least two accounts first")
	}
	switch args[0] {
	case "enable":
		if !*ack {
			return 2, errors.New("--acknowledge-cross-account-context is required")
		}
		if err := session.Enable(paths, cfg); err != nil {
			return 1, err
		}
	case "disable":
		if err := session.Disable(paths, cfg); err != nil {
			return 1, err
		}
	default:
		return 2, fmt.Errorf("unknown sessions command %q", args[0])
	}
	if err := config.Save(paths, *cfg); err != nil {
		return 1, err
	}
	fmt.Printf("session sharing %sd\n", args[0])
	return 0, nil
}

func shimCommand(paths config.Paths, args []string) (int, error) {
	if len(args) == 0 {
		return 2, errors.New("shim requires install or remove")
	}
	home, _ := os.UserHomeDir()
	flags := newFlags("shim " + args[0])
	dir := flags.String("dir", filepath.Join(home, ".local", "bin"), "directory that should contain codex")
	force := flags.Bool("force", false, "back up and replace an existing codex entry")
	if err := flags.Parse(args[1:]); err != nil {
		return 2, err
	}
	if flags.NArg() != 0 {
		return 2, errors.New("unexpected shim arguments")
	}
	resolvedDir, err := config.ExpandPath(*dir)
	if err != nil {
		return 1, err
	}
	target := filepath.Join(resolvedDir, "codex")
	self, err := os.Executable()
	if err != nil {
		return 1, err
	}
	self, err = filepath.EvalSymlinks(self)
	if err != nil {
		return 1, err
	}
	switch args[0] {
	case "install":
		if err := os.MkdirAll(resolvedDir, 0o700); err != nil {
			return 1, err
		}
		if info, err := os.Lstat(target); err == nil {
			if actual, evalErr := filepath.EvalSymlinks(target); evalErr == nil && actual == self {
				fmt.Printf("shim already installed at %s\n", target)
				return 0, nil
			}
			if info.IsDir() {
				return 2, fmt.Errorf("refusing directory %s", target)
			}
			if !*force {
				return 2, fmt.Errorf("%s exists; use --force to create a recoverable backup", target)
			}
			backup := target + ".cab-backup-" + time.Now().UTC().Format("20060102T150405Z")
			if err := os.Rename(target, backup); err != nil {
				return 1, err
			}
			fmt.Printf("backed up %s to %s\n", target, backup)
		} else if !errors.Is(err, fs.ErrNotExist) {
			return 1, err
		}
		if err := os.Symlink(self, target); err != nil {
			return 1, err
		}
		fmt.Printf("installed remote shim at %s\n", target)
		fmt.Printf("ensure %s precedes the official Codex directory in the SSH login PATH\n", resolvedDir)
		_ = paths
		return 0, nil
	case "remove":
		actual, err := filepath.EvalSymlinks(target)
		if err != nil || actual != self {
			return 2, fmt.Errorf("refusing to remove a shim not owned by cab: %s", target)
		}
		if err := os.Remove(target); err != nil {
			return 1, err
		}
		backups, _ := filepath.Glob(target + ".cab-backup-*")
		sort.Strings(backups)
		if len(backups) > 0 {
			backup := backups[len(backups)-1]
			if err := os.Rename(backup, target); err != nil {
				return 1, err
			}
			fmt.Printf("removed shim and restored %s\n", backup)
		} else {
			fmt.Printf("removed shim %s\n", target)
		}
		return 0, nil
	default:
		return 2, fmt.Errorf("unknown shim command %q", args[0])
	}
}

func doctor(paths config.Paths, cfg config.Config) (int, error) {
	issues := 0
	check := func(ok bool, message string) {
		if ok {
			fmt.Printf("OK   %s\n", message)
		} else {
			fmt.Printf("FAIL %s\n", message)
			issues++
		}
	}
	_, err := codex.FindReal("codex")
	check(err == nil, "official codex executable is reachable")
	check(len(cfg.Accounts) > 0, "at least one account is configured")
	for _, account := range cfg.Accounts {
		info, err := os.Lstat(account.Home)
		check(err == nil && info.IsDir() && info.Mode()&os.ModeSymlink == 0, account.Name+" home is a real directory")
		if err == nil {
			check(info.Mode().Perm()&0o077 == 0, account.Name+" home permissions exclude group/other")
		}
		loggedIn, loginErr := codex.LoggedIn(account.Home)
		check(loginErr == nil && loggedIn, account.Name+" is logged in through the official Codex CLI")
		authInfo, authErr := os.Lstat(filepath.Join(account.Home, "auth.json"))
		if authErr == nil {
			check(authInfo.Mode().IsRegular() && authInfo.Mode()&os.ModeSymlink == 0, account.Name+" auth.json is a regular file")
			check(authInfo.Mode().Perm()&0o077 == 0, account.Name+" auth.json permissions exclude group/other")
		} else if !errors.Is(authErr, fs.ErrNotExist) {
			check(false, account.Name+" auth storage can be inspected safely")
		}
	}
	if cfg.SharedSessionsDir != "" {
		for _, account := range cfg.Accounts {
			target := filepath.Join(account.Home, "sessions")
			actual, err := filepath.EvalSymlinks(target)
			shared, sharedErr := filepath.EvalSymlinks(cfg.SharedSessionsDir)
			check(err == nil && sharedErr == nil && filepath.Clean(actual) == filepath.Clean(shared), account.Name+" sessions link targets the shared store")
		}
	}
	check(paths.File != "", "config path resolved")
	if issues > 0 {
		return 1, fmt.Errorf("doctor found %d issue(s)", issues)
	}
	return 0, nil
}

func selectedAccount(cfg config.Config, name string) (config.Account, error) {
	if name == "" {
		return config.Account{}, errors.New("no account selected; run cab use NAME")
	}
	account, ok := cfg.Find(name)
	if !ok {
		return config.Account{}, fmt.Errorf("unknown account %q", name)
	}
	return account, nil
}

func ensureAccountHome(path string) error {
	if info, err := os.Lstat(path); err == nil {
		if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
			return fmt.Errorf("refusing unsafe account home: %s", path)
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

func authStatus(home string) string {
	loggedIn, err := codex.LoggedIn(home)
	if err != nil {
		return "unknown"
	}
	if !loggedIn {
		return "missing"
	}
	return "present"
}

func marker(selected, name string) string {
	if strings.EqualFold(selected, name) {
		return "yes"
	}
	return "-"
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if value != "" {
			return value
		}
	}
	return ""
}

func newFlags(name string) *flag.FlagSet {
	flags := flag.NewFlagSet(name, flag.ContinueOnError)
	flags.SetOutput(os.Stderr)
	return flags
}
