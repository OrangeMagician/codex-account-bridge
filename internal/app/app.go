package app

import (
	"errors"
	"flag"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
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
		return runCommand(cfg, args, false)
	case "app-server":
		return runCommand(cfg, args, true)
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
  cab account list
  cab account remove NAME
  cab use NAME
  cab login [--device-auth] NAME
  cab run [--account NAME] -- [codex arguments]
  cab app-server [--account NAME] -- [app-server arguments]
  cab remote use NAME
  cab sessions enable --acknowledge-cross-account-context --confirm-codex-stopped
  cab sessions disable --confirm-codex-stopped
  cab shim install [--dir PATH] [--force]
  cab shim remove [--dir PATH]
  cab doctor
  cab version

Safety defaults: no quota rotation, no proxy, no auth copying, no automatic
project trust, and no approval/sandbox bypass flags.
`)
}

func accountCommand(paths config.Paths, cfg *config.Config, args []string) (int, error) {
	if len(args) == 0 {
		return 2, errors.New("account requires add, list, or remove")
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
		fmt.Printf("next: cab login --device-auth %s\n", name)
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
		next := cfg.Accounts[:0]
		for _, account := range cfg.Accounts {
			if !strings.EqualFold(account.Name, name) {
				next = append(next, account)
			}
		}
		cfg.Accounts = next
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
	if err := flags.Parse(args); err != nil {
		return 2, err
	}
	if flags.NArg() != 1 {
		return 2, errors.New("usage: cab login [--device-auth] NAME")
	}
	account, ok := cfg.Find(flags.Arg(0))
	if !ok {
		return 2, fmt.Errorf("unknown account %q", flags.Arg(0))
	}
	loginArgs := []string{"login"}
	if *device {
		loginArgs = append(loginArgs, "--device-auth")
	}
	return codex.Run(account.Home, loginArgs)
}

func runCommand(cfg config.Config, args []string, appServer bool) (int, error) {
	flags := newFlags("run")
	accountName := flags.String("account", "", "configured account name")
	if err := flags.Parse(args); err != nil {
		return 2, err
	}
	account, err := selectedAccount(cfg, firstNonEmpty(*accountName, cfg.DefaultAccount))
	if err != nil {
		return 2, err
	}
	commandArgs := flags.Args()
	if appServer {
		commandArgs = append([]string{"app-server"}, commandArgs...)
	}
	return codex.Run(account.Home, commandArgs)
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
		authInfo, authErr := os.Lstat(filepath.Join(account.Home, "auth.json"))
		check(authErr == nil && authInfo.Mode().IsRegular() && authInfo.Mode()&os.ModeSymlink == 0, account.Name+" has a regular auth.json")
		if authErr == nil {
			check(authInfo.Mode().Perm()&0o077 == 0, account.Name+" auth.json permissions exclude group/other")
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
	info, err := os.Lstat(filepath.Join(home, "auth.json"))
	if err != nil || !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 {
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
