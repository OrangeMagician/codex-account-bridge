package app

import (
	"errors"
	"fmt"

	"github.com/OrangeMagician/codex-account-bridge/internal/config"
	"github.com/OrangeMagician/codex-account-bridge/internal/localapi"
)

func localAPICommand(paths config.Paths, args []string) (int, error) {
	const usage = "cab api use NAME | status | key | start|serve [--listen IP:PORT --client IP] | stop"
	if len(args) == 0 {
		return 2, errors.New(usage)
	}
	var err error
	switch args[0] {
	case "use":
		if len(args) != 2 {
			return 2, errors.New(usage)
		}
		err = config.SelectAPIAccount(paths, args[1])
	case "start", "serve":
		flags := newFlags("api " + args[0])
		listen := flags.String("listen", "127.0.0.1:8787", "listener address")
		client := flags.String("client", "127.0.0.1", "allowed client IP")
		if err = flags.Parse(args[1:]); err != nil || flags.NArg() != 0 {
			return 2, errors.New(usage)
		}
		if args[0] == "serve" {
			err = localapi.Serve(paths, *listen, *client)
		} else {
			_, err = config.ReadLocked(paths, func(config.Config) error { return localapi.Start(paths, *listen, *client) })
		}
	case "stop":
		if len(args) != 1 {
			return 2, errors.New(usage)
		}
		_, err = config.ReadLocked(paths, func(config.Config) error { return localapi.Stop() })
	case "status":
		if len(args) != 1 {
			return 2, errors.New(usage)
		}
		status, err := localapi.GetStatus(paths)
		if err != nil {
			return 1, err
		}
		return printJSON(status)
	case "key":
		if len(args) != 1 {
			return 2, errors.New(usage)
		}
		settings, err := config.ReadAPISettings(paths)
		if err != nil {
			return 1, err
		}
		if settings.Key == "" {
			return 1, errors.New("select an API account first")
		}
		fmt.Println(settings.Key)
	default:
		return 2, errors.New(usage)
	}
	if err != nil {
		return 1, err
	}
	return 0, nil
}
