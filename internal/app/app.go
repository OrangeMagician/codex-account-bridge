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
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/OrangeMagician/codex-account-bridge/internal/agentbinding"
	"github.com/OrangeMagician/codex-account-bridge/internal/codex"
	"github.com/OrangeMagician/codex-account-bridge/internal/codexprocess"
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
		cfg, err := config.ReadLocked(paths, func(latest config.Config) error {
			return session.Recover(paths, latest)
		})
		if err != nil {
			return 1, err
		}
		account, err := selectedAccount(cfg, cfg.RemoteAccount)
		if err != nil {
			return 2, fmt.Errorf("remote shim: %w", err)
		}
		unlock, err := session.AcquireRunLease(paths)
		if err != nil {
			return 1, err
		}
		defer unlock()
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
		if err := config.EnsureDataDir(paths); err != nil {
			return 1, err
		}
		if _, err := config.UpdateSimple(paths, func(*config.Config) error { return nil }); err != nil {
			return 1, err
		}
		fmt.Printf("initialized %s\n", paths.File)
		return 0, nil
	}
	if command == "doctor" {
		flags := newFlags("doctor")
		repair := flags.Bool("repair", false, "recover an interrupted CAB session transaction")
		if err := flags.Parse(args); err != nil || flags.NArg() != 0 {
			return 2, errors.New("usage: cab doctor [--repair]")
		}
		cfg, err := config.ReadLocked(paths, func(latest config.Config) error {
			if *repair {
				return session.Recover(paths, latest)
			}
			return nil
		})
		if err != nil {
			return 1, err
		}
		return doctor(paths, cfg)
	}
	cfg, err := config.ReadLocked(paths, func(latest config.Config) error {
		return session.Recover(paths, latest)
	})
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
	case "usage":
		return usageCommand(cfg, args)
	case "agent":
		return agentCommand(cfg, args)
	case "processes":
		return processesCommand(args)
	case "sessions":
		return sessionsCommand(paths, &cfg, args)
	case "shim":
		return shimCommand(paths, args)
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
  cab usage [--account NAME] [--json]
  cab agent list [--json]
  cab agent bind --service UNIT --account NAME --confirm-restart-agent
  cab agent bind-all --account NAME --confirm-restart-agent
  cab agent unbind --service UNIT --confirm-restart-agent
  cab processes list [--json]
  cab processes stop --pids PID,PID --confirm-stop-codex
  cab rotation status [--json]
  cab rotation configure --accounts NAME,NAME
  cab rotation enable|disable|reset
  cab remote use NAME
  cab sessions enable --acknowledge-cross-account-context --confirm-codex-stopped
  cab sessions disable --confirm-codex-stopped
  cab sessions legacy-status [--json]
  cab sessions import-current --acknowledge-cross-account-context --confirm-codex-stopped
  cab shim install [--dir PATH] [--force]
  cab shim remove [--dir PATH]
  cab doctor [--repair]
  cab version

Safety defaults: launch rotation is opt-in and never reacts to quota/errors;
no proxy, auth copying, automatic project trust, or approval/sandbox bypass.
`)
}

func processesCommand(args []string) (int, error) {
	if len(args) == 0 {
		return 2, errors.New("processes requires list or stop")
	}
	switch args[0] {
	case "list":
		flags := newFlags("processes list")
		jsonOutput := flags.Bool("json", false, "print machine-readable JSON")
		if err := flags.Parse(args[1:]); err != nil {
			return 2, err
		}
		if flags.NArg() != 0 {
			return 2, errors.New("usage: cab processes list [--json]")
		}
		processes, err := codexprocess.List()
		if err != nil {
			return 1, err
		}
		if *jsonOutput {
			return printJSON(struct {
				Processes []codexprocess.Process `json:"processes"`
			}{processes})
		}
		if len(processes) == 0 {
			fmt.Println("No Codex processes are running.")
			return 0, nil
		}
		fmt.Println("PID\tELAPSED\tTTY\tSTATE\tEXECUTABLE")
		for _, process := range processes {
			fmt.Printf("%d\t%s\t%s\t%s\t%s\n", process.PID, process.Elapsed, process.TTY, process.State, process.Executable)
		}
		return 0, nil
	case "stop":
		flags := newFlags("processes stop")
		values := flags.String("pids", "", "comma-separated PIDs from processes list")
		confirm := flags.Bool("confirm-stop-codex", false, "confirm normal termination of listed Codex processes")
		if err := flags.Parse(args[1:]); err != nil {
			return 2, err
		}
		if flags.NArg() != 0 || *values == "" || !*confirm {
			return 2, errors.New("usage: cab processes stop --pids PID,PID --confirm-stop-codex")
		}
		var pids []int
		for _, value := range strings.Split(*values, ",") {
			pid, err := strconv.Atoi(strings.TrimSpace(value))
			if err != nil || pid <= 0 {
				return 2, fmt.Errorf("invalid PID %q", value)
			}
			pids = append(pids, pid)
		}
		if err := codexprocess.Stop(pids); err != nil {
			return 1, err
		}
		fmt.Printf("stopped %d requested Codex process(es)\n", len(pids))
		return 0, nil
	default:
		return 2, fmt.Errorf("unknown processes command %q", args[0])
	}
}

func agentCommand(cfg config.Config, args []string) (int, error) {
	if len(args) == 0 {
		return 2, errors.New("agent requires list, bind, or unbind")
	}
	manager, err := agentbinding.DefaultManager()
	if err != nil {
		return 1, err
	}
	homes := make(map[string]string, len(cfg.Accounts))
	for _, account := range cfg.Accounts {
		homes[account.Name] = account.Home
	}
	switch args[0] {
	case "list":
		flags := newFlags("agent list")
		jsonOutput := flags.Bool("json", false, "print machine-readable JSON")
		if err := flags.Parse(args[1:]); err != nil {
			return 2, err
		}
		if flags.NArg() != 0 {
			return 2, errors.New("usage: cab agent list [--json]")
		}
		bindings, err := manager.List(homes)
		if err != nil {
			return 1, err
		}
		if *jsonOutput {
			return printJSON(struct {
				Agents []agentbinding.Binding `json:"agents"`
			}{bindings})
		}
		if len(bindings) == 0 {
			fmt.Println("No supported agent services found.")
			return 0, nil
		}
		fmt.Println("SERVICE\tKIND\tACTIVE\tACCOUNT")
		for _, binding := range bindings {
			fmt.Printf("%s\t%s\t%t\t%s\n", binding.Service, binding.Kind, binding.Active, markerValue(binding.Account, "unbound"))
		}
		return 0, nil
	case "bind":
		flags := newFlags("agent bind")
		service := flags.String("service", "", "supported systemd user service")
		accountName := flags.String("account", "", "configured Codex account")
		confirm := flags.Bool("confirm-restart-agent", false, "confirm interruption of an active agent")
		if err := flags.Parse(args[1:]); err != nil {
			return 2, err
		}
		if flags.NArg() != 0 || *service == "" || *accountName == "" {
			return 2, errors.New("usage: cab agent bind --service UNIT --account NAME --confirm-restart-agent")
		}
		account, ok := cfg.Find(*accountName)
		if !ok {
			return 2, fmt.Errorf("unknown account %q", *accountName)
		}
		loggedIn, err := codex.LoggedIn(account.Home)
		if err != nil {
			return 1, fmt.Errorf("check account login: %w", err)
		}
		if !loggedIn {
			return 2, fmt.Errorf("account %q is not logged in", account.Name)
		}
		if err := manager.Bind(*service, account.Home, *confirm); err != nil {
			return 1, err
		}
		fmt.Printf("bound %s to %s\n", *service, account.Name)
		return 0, nil
	case "bind-all":
		flags := newFlags("agent bind-all")
		accountName := flags.String("account", "", "configured Codex account")
		confirm := flags.Bool("confirm-restart-agent", false, "confirm interruption of active agents")
		if err := flags.Parse(args[1:]); err != nil {
			return 2, err
		}
		if flags.NArg() != 0 || *accountName == "" {
			return 2, errors.New("usage: cab agent bind-all --account NAME --confirm-restart-agent")
		}
		account, ok := cfg.Find(*accountName)
		if !ok {
			return 2, fmt.Errorf("unknown account %q", *accountName)
		}
		loggedIn, err := codex.LoggedIn(account.Home)
		if err != nil {
			return 1, fmt.Errorf("check account login: %w", err)
		}
		if !loggedIn {
			return 2, fmt.Errorf("account %q is not logged in", account.Name)
		}
		bindings, err := manager.List(homes)
		if err != nil {
			return 1, err
		}
		changed := make([]agentbinding.Binding, 0, len(bindings))
		for _, binding := range bindings {
			if binding.Account != account.Name {
				changed = append(changed, binding)
			}
		}
		if len(changed) == 0 {
			fmt.Printf("all supported agent services already use %s\n", account.Name)
			return 0, nil
		}
		if !*confirm {
			for _, binding := range changed {
				if binding.Active {
					return 2, errors.New("one or more changed services are active; pass --confirm-restart-agent after saving all agent tasks")
				}
			}
		}
		var failures []string
		bound := 0
		for _, binding := range changed {
			if err := manager.Bind(binding.Service, account.Home, *confirm); err != nil {
				failures = append(failures, fmt.Sprintf("%s: %v", binding.Service, err))
				continue
			}
			bound++
			fmt.Printf("bound %s to %s\n", binding.Service, account.Name)
		}
		if len(failures) > 0 {
			return 1, fmt.Errorf("bound %d service(s); failed: %s", bound, strings.Join(failures, "; "))
		}
		fmt.Printf("bound %d supported agent service(s) to %s\n", bound, account.Name)
		return 0, nil
	case "unbind":
		flags := newFlags("agent unbind")
		service := flags.String("service", "", "supported systemd user service")
		confirm := flags.Bool("confirm-restart-agent", false, "confirm interruption of an active agent")
		if err := flags.Parse(args[1:]); err != nil {
			return 2, err
		}
		if flags.NArg() != 0 || *service == "" {
			return 2, errors.New("usage: cab agent unbind --service UNIT --confirm-restart-agent")
		}
		if err := manager.Unbind(*service, *confirm); err != nil {
			return 1, err
		}
		fmt.Printf("removed CAB binding from %s\n", *service)
		return 0, nil
	default:
		return 2, fmt.Errorf("unknown agent command %q", args[0])
	}
}

func markerValue(value, fallback string) string {
	if value == "" {
		return fallback
	}
	return value
}

type accountUsageOutput struct {
	Name  string               `json:"name"`
	Usage *codex.UsageSnapshot `json:"usage,omitempty"`
	Error string               `json:"error,omitempty"`
}

type usageOutput struct {
	FetchedAt string               `json:"fetched_at"`
	Accounts  []accountUsageOutput `json:"accounts"`
}

func usageCommand(cfg config.Config, args []string) (int, error) {
	flags := newFlags("usage")
	accountName := flags.String("account", "", "configured account name")
	jsonOutput := flags.Bool("json", false, "print machine-readable JSON")
	if err := flags.Parse(args); err != nil {
		return 2, err
	}
	if flags.NArg() != 0 {
		return 2, errors.New("usage: cab usage [--account NAME] [--json]")
	}
	accounts := cfg.Accounts
	if *accountName != "" {
		account, ok := cfg.Find(*accountName)
		if !ok {
			return 2, fmt.Errorf("unknown account %q", *accountName)
		}
		accounts = []config.Account{account}
	}
	if len(accounts) == 0 {
		return 2, errors.New("no accounts configured")
	}

	report := usageOutput{FetchedAt: time.Now().UTC().Format(time.RFC3339), Accounts: make([]accountUsageOutput, len(accounts))}
	limit := make(chan struct{}, 4)
	var wait sync.WaitGroup
	for index, account := range accounts {
		index, account := index, account
		wait.Add(1)
		go func() {
			defer wait.Done()
			limit <- struct{}{}
			defer func() { <-limit }()
			item := accountUsageOutput{Name: account.Name}
			usage, err := codex.ReadUsage(account.Home)
			if err != nil {
				if strings.Contains(err.Error(), "ChatGPT login is required") {
					item.Error = "account is not logged in"
				} else {
					item.Error = err.Error()
				}
			} else {
				item.Usage = &usage
			}
			report.Accounts[index] = item
		}()
	}
	wait.Wait()
	if *jsonOutput {
		return printJSON(report)
	}
	for _, item := range report.Accounts {
		if item.Error != "" {
			fmt.Printf("%s\terror\t%s\n", item.Name, item.Error)
			continue
		}
		primary := item.Usage.RateLimits.Primary
		if primary == nil {
			fmt.Printf("%s\t%s\tusage unavailable\n", item.Name, item.Usage.PlanType)
			continue
		}
		remaining := 100 - primary.UsedPercent
		reset := "unknown"
		if primary.ResetsAt != nil {
			reset = time.Unix(*primary.ResetsAt, 0).Local().Format(time.RFC3339)
		}
		fmt.Printf("%s\t%s\t%.1f%% remaining\tresets %s\n", item.Name, item.Usage.PlanType, remaining, reset)
	}
	return 0, nil
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
		if err := config.ValidateAccountName(name); err != nil {
			return 2, err
		}
		home := *homeFlag
		if home == "" {
			home = filepath.Join(paths.DataDir, "accounts", name)
		}
		home, err := config.ExpandPath(home)
		if err != nil {
			return 1, err
		}
		if config.PathsOverlap(home, paths.ConfigDir) {
			return 2, errors.New("account home cannot overlap the CAB config directory")
		}
		updated, err := config.Update(paths, func(latest *config.Config) (config.Mutation, error) {
			if latest.SharedSessionsDir != "" {
				return config.Mutation{}, errors.New("disable session sharing before adding an account")
			}
			if _, ok := latest.Find(name); ok {
				return config.Mutation{}, fmt.Errorf("account %q already exists", name)
			}
			mutation, prepareErr := prepareAccountHome(home)
			if prepareErr != nil {
				return config.Mutation{}, prepareErr
			}
			return mutation, latest.Add(config.Account{Name: name, Home: home})
		})
		if err != nil {
			return 1, err
		}
		*cfg = updated
		fmt.Printf("added %s at %s\n", name, home)
		fmt.Printf("next: cab login %s\n", name)
		return 0, nil
	case "import-current":
		if len(args) != 2 {
			return 2, errors.New("usage: cab account import-current NAME")
		}
		if err := config.ValidateAccountName(args[1]); err != nil {
			return 2, err
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
		updated, err := config.Update(paths, func(latest *config.Config) (config.Mutation, error) {
			if latest.SharedSessionsDir != "" {
				return config.Mutation{}, errors.New("disable session sharing before importing an account")
			}
			for _, account := range latest.Accounts {
				if filepath.Clean(account.Home) == filepath.Clean(home) {
					return config.Mutation{}, fmt.Errorf("current Codex home is already registered as %q", account.Name)
				}
			}
			mutation, prepareErr := prepareAccountHome(home)
			if prepareErr != nil {
				return config.Mutation{}, prepareErr
			}
			return mutation, latest.Add(config.Account{Name: args[1], Home: home})
		})
		if err != nil {
			return 1, err
		}
		*cfg = updated
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
		updated, err := config.UpdateSimple(paths, func(latest *config.Config) error {
			if latest.SharedSessionsDir != "" {
				return errors.New("disable session sharing before removing an account")
			}
			if _, ok := latest.Find(name); !ok {
				return fmt.Errorf("unknown account %q", name)
			}
			latest.Remove(name)
			if strings.EqualFold(latest.DefaultAccount, name) {
				latest.DefaultAccount = ""
				if len(latest.Accounts) > 0 {
					latest.DefaultAccount = latest.Accounts[0].Name
				}
			}
			if strings.EqualFold(latest.RemoteAccount, name) {
				latest.RemoteAccount = ""
			}
			return nil
		})
		if err != nil {
			return 1, err
		}
		*cfg = updated
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
	updated, err := config.UpdateSimple(paths, func(latest *config.Config) error {
		current, ok := latest.Find(account.Name)
		if !ok {
			return fmt.Errorf("unknown account %q", account.Name)
		}
		if remote {
			latest.RemoteAccount = current.Name
		} else {
			latest.DefaultAccount = current.Name
		}
		return nil
	})
	if err != nil {
		return 1, err
	}
	*cfg = updated
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
	unlock, err := session.AcquireRunLease(paths)
	if err != nil {
		return 1, err
	}
	defer unlock()
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
		updated, err := config.UpdateSimple(paths, func(latest *config.Config) error {
			return latest.SetRotationAccounts(names)
		})
		if err != nil {
			return 1, err
		}
		*cfg = updated
		fmt.Printf("rotation order: %s\n", strings.Join(cfg.Rotation.Accounts, ", "))
		return 0, nil
	case "enable":
		if len(args) != 1 {
			return 2, errors.New("usage: cab rotation enable")
		}
		if len(cfg.Rotation.Accounts) < 2 {
			return 2, errors.New("configure at least two rotation accounts first")
		}
		updated, err := config.UpdateSimple(paths, func(latest *config.Config) error {
			if len(latest.Rotation.Accounts) < 2 {
				return errors.New("configure at least two rotation accounts first")
			}
			latest.Rotation.Enabled = true
			return nil
		})
		if err != nil {
			return 1, err
		}
		*cfg = updated
		fmt.Println("launch rotation enabled; quota and errors never trigger switching")
		return 0, nil
	case "disable":
		if len(args) != 1 {
			return 2, errors.New("usage: cab rotation disable")
		}
		updated, err := config.UpdateSimple(paths, func(latest *config.Config) error {
			latest.Rotation.Enabled = false
			return nil
		})
		if err != nil {
			return 1, err
		}
		*cfg = updated
		fmt.Println("launch rotation disabled")
		return 0, nil
	case "reset":
		if len(args) != 1 {
			return 2, errors.New("usage: cab rotation reset")
		}
		updated, err := config.UpdateSimple(paths, func(latest *config.Config) error {
			latest.Rotation.NextIndex = 0
			return nil
		})
		if err != nil {
			return 1, err
		}
		*cfg = updated
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
	var account config.Account
	_, err := config.UpdateSimple(paths, func(latest *config.Config) error {
		var err error
		account, err = latest.NextRotationAccount()
		return err
	})
	if err != nil {
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
	if args[0] == "legacy-status" {
		flags := newFlags("sessions legacy-status")
		jsonOutput := flags.Bool("json", false, "print machine-readable JSON")
		if err := flags.Parse(args[1:]); err != nil {
			return 2, err
		}
		if flags.NArg() != 0 {
			return 2, errors.New("usage: cab sessions legacy-status [--json]")
		}
		home, err := config.DefaultCodexHome()
		if err != nil {
			return 1, err
		}
		report, err := session.LegacyStatus(*cfg, home)
		if err != nil {
			return 1, err
		}
		if *jsonOutput {
			return printJSON(report)
		}
		fmt.Printf("%d sessions and %d archived sessions in %s\n", report.Sessions, report.ArchivedSessions, report.SourceHome)
		return 0, nil
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
	running, err := codexprocess.List()
	if err != nil {
		return 1, err
	}
	if len(running) > 0 {
		pids := make([]string, 0, len(running))
		for _, process := range running {
			pids = append(pids, strconv.Itoa(process.PID))
		}
		return 2, fmt.Errorf("Codex is still running (PIDs %s); close it before changing session sharing", strings.Join(pids, ", "))
	}
	if args[0] == "import-current" {
		if !*ack {
			return 2, errors.New("--acknowledge-cross-account-context is required")
		}
		home, err := config.DefaultCodexHome()
		if err != nil {
			return 1, err
		}
		var report session.LegacyReport
		_, err = config.ReadLocked(paths, func(latest config.Config) error {
			var importErr error
			report, importErr = session.ImportLegacy(paths, latest, home)
			return importErr
		})
		if err != nil {
			return 1, err
		}
		fmt.Printf("imported %d sessions and %d archived sessions from %s\n", report.Sessions, report.ArchivedSessions, report.SourceHome)
		return 0, nil
	}
	if args[0] != "enable" && args[0] != "disable" {
		return 2, fmt.Errorf("unknown sessions command %q", args[0])
	}
	if args[0] == "enable" && !*ack {
		return 2, errors.New("--acknowledge-cross-account-context is required")
	}
	updated, err := config.Update(paths, func(latest *config.Config) (config.Mutation, error) {
		if args[0] == "enable" && len(latest.Accounts) < 2 {
			return config.Mutation{}, errors.New("configure at least two accounts first")
		}
		running, listErr := codexprocess.List()
		if listErr != nil {
			return config.Mutation{}, listErr
		}
		if len(running) > 0 {
			pids := make([]string, 0, len(running))
			for _, process := range running {
				pids = append(pids, strconv.Itoa(process.PID))
			}
			return config.Mutation{}, fmt.Errorf("Codex started while preparing the operation (PIDs %s); close it and retry", strings.Join(pids, ", "))
		}
		if args[0] == "enable" {
			return session.PrepareEnable(paths, latest)
		}
		return session.PrepareDisable(paths, latest)
	})
	if err != nil {
		return 1, err
	}
	*cfg = updated
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
	if resolvedDir == string(filepath.Separator) {
		return 2, errors.New("shim directory cannot be filesystem root")
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
		backup := ""
		if info, err := os.Lstat(resolvedDir); err == nil {
			if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
				return 2, fmt.Errorf("refusing unsafe shim directory: %s", resolvedDir)
			}
		} else if !errors.Is(err, fs.ErrNotExist) {
			return 1, err
		}
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
			backup = target + ".cab-backup-" + time.Now().UTC().Format("20060102T150405Z")
			if err := os.Rename(target, backup); err != nil {
				return 1, err
			}
			fmt.Printf("backed up %s to %s\n", target, backup)
		} else if !errors.Is(err, fs.ErrNotExist) {
			return 1, err
		}
		if err := os.Symlink(self, target); err != nil {
			if backup != "" {
				if restoreErr := os.Rename(backup, target); restoreErr != nil {
					return 1, fmt.Errorf("install shim: %w; restore previous entry: %v", err, restoreErr)
				}
			}
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
			for _, name := range []string{"sessions", "archived_sessions"} {
				target := filepath.Join(account.Home, name)
				sharedTarget := cfg.SharedSessionsDir
				if name != "sessions" {
					sharedTarget = filepath.Join(filepath.Dir(cfg.SharedSessionsDir), name)
				}
				actual, err := filepath.EvalSymlinks(target)
				shared, sharedErr := filepath.EvalSymlinks(sharedTarget)
				check(err == nil && sharedErr == nil && filepath.Clean(actual) == filepath.Clean(shared), account.Name+" "+name+" link targets the shared store")
			}
		}
	}
	check(paths.File != "", "config path resolved")
	pendingRecovery, recoveryErr := session.RecoveryStatus(paths, cfg)
	check(recoveryErr == nil, "session transaction journal is valid")
	check(!pendingRecovery, "no interrupted session transaction requires recovery")
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
	if !filepath.IsAbs(path) || filepath.Clean(path) == string(filepath.Separator) {
		return fmt.Errorf("refusing unsafe account home: %s", path)
	}
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

func prepareAccountHome(path string) (config.Mutation, error) {
	_, err := os.Lstat(path)
	created := errors.Is(err, fs.ErrNotExist)
	if err != nil && !created {
		return config.Mutation{}, err
	}
	if err := ensureAccountHome(path); err != nil {
		return config.Mutation{}, err
	}
	if !created {
		return config.Mutation{}, nil
	}
	return config.Mutation{Rollback: func() error {
		err := os.Remove(path)
		if errors.Is(err, fs.ErrNotExist) {
			return nil
		}
		return err
	}}, nil
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
