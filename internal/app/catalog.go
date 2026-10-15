package app

import (
	"errors"
	"fmt"
	"path/filepath"
	"strconv"

	"github.com/OrangeMagician/codex-account-bridge/internal/codex"
	"github.com/OrangeMagician/codex-account-bridge/internal/config"
)

func modelsCommand(cfg config.Config, args []string) (int, error) {
	f := newFlags("models")
	name := f.String("account", "", "explicit account")
	jsonOutput := f.Bool("json", false, "JSON")
	if err := f.Parse(args); err != nil || f.NArg() != 0 || *name == "" {
		return 2, errors.New("usage: cab models --account NAME [--json]")
	}
	a, err := selectedAccount(cfg, *name)
	if err != nil {
		return 2, err
	}
	result, err := codex.ReadModels(a.Home)
	if err != nil {
		return 1, err
	}
	if *jsonOutput {
		return printJSON(result)
	}
	for _, m := range result.Models {
		fmt.Printf("%s\t%s\tdefault=%t\n", m.Model, m.DisplayName, m.IsDefault)
	}
	return 0, nil
}

func tasksCommand(cfg config.Config, args []string) (int, error) {
	if len(args) == 0 {
		return 2, errors.New("tasks requires list or pin")
	}
	f := newFlags("tasks")
	name := f.String("account", "", "explicit account")
	jsonOutput := f.Bool("json", false, "JSON")
	search := f.String("search", "", "title search")
	directory := f.String("directory", "", "project path")
	cursor := f.String("cursor", "", "pagination cursor")
	archived := f.Bool("archived", false, "archived history")
	pinned := f.Bool("pinned", false, "pinned history only")
	id := f.String("id", "", "task ID")
	value := f.String("value", "", "true or false")
	if err := f.Parse(args[1:]); err != nil || f.NArg() != 0 || *name == "" {
		return 2, errors.New("tasks requires an explicit --account NAME")
	}
	a, err := selectedAccount(cfg, *name)
	if err != nil {
		return 2, err
	}
	switch args[0] {
	case "list":
		if *directory != "" && !filepath.IsAbs(*directory) {
			return 2, errors.New("project directory must be absolute")
		}
		page, err := codex.ReadTasks(a.Home, codex.TaskFilter{Search: *search, Directory: *directory, Cursor: *cursor, Archived: *archived, PinnedOnly: *pinned})
		if err != nil {
			return 1, err
		}
		if *jsonOutput {
			return printJSON(page)
		}
		for _, task := range page.Tasks {
			title := task.ID
			if task.Name != nil {
				title = *task.Name
			}
			fmt.Printf("%s\t%s\t%s\n", task.ID, title, task.CWD)
		}
		return 0, nil
	case "pin":
		v, err := strconv.ParseBool(*value)
		if err != nil || *id == "" {
			return 2, errors.New("usage: cab tasks pin --account NAME --id ID --value true|false [--json]")
		}
		if err = codex.SetTaskPinned(a.Home, *id, v); err != nil {
			return 1, err
		}
		if *jsonOutput {
			return printJSON(map[string]any{"completed": true})
		}
		fmt.Println("task pin updated")
		return 0, nil
	default:
		return 2, errors.New("tasks requires list or pin")
	}
}
