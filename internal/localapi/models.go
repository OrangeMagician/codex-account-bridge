package localapi

import (
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/OrangeMagician/codex-account-bridge/internal/codex"
)

// A compound ID makes every choice available in clients that expose only a model picker.
// Raw model IDs can be used by clients that send the standard request fields.
func (r chatRequest) launchOptions() (codex.LaunchOptions, error) {
	parts := strings.Split(r.Model, "@")
	options := codex.LaunchOptions{Model: parts[0], Effort: r.ReasoningEffort, Speed: r.ServiceTier}

	if len(parts) == 2 && parts[1] == "fast" {
		if options.Speed != "" && options.Speed != "fast" {
			return options, errors.New("service_tier conflicts with model ID")
		}
		options.Speed = "fast"
	} else if len(parts) == 2 || len(parts) == 3 {
		if options.Effort != "" && options.Effort != parts[1] {
			return options, errors.New("reasoning_effort conflicts with model ID")
		}
		options.Effort = parts[1]
		if len(parts) == 3 {
			if options.Speed != "" && options.Speed != parts[2] {
				return options, errors.New("service_tier conflicts with model ID")
			}
			options.Speed = parts[2]
		}
	} else if len(parts) != 1 {
		return options, errors.New("model ID must be MODEL, MODEL@EFFORT or MODEL@EFFORT@SPEED")
	}
	if options.Model == "" || options.Model == "cab-codex" {
		return options, errors.New("choose an explicit model from /v1/models")
	}
	if len(parts) > 1 && parts[1] != "fast" && options.Effort == "" {
		return options, errors.New("reasoning effort cannot be empty")
	}
	if len(parts) == 3 && options.Speed == "" {
		return options, errors.New("speed cannot be empty")
	}
	if options.Effort == "" {
		options.Effort = "medium"
	}
	if options.Speed == "" {
		options.Speed = "standard"
	}
	if options.Speed == "default" {
		options.Speed = "standard"
	}
	if options.Speed == "priority" {
		options.Speed = "fast"
	}
	if options.Speed != "standard" && options.Speed != "fast" {
		return options, errors.New("speed must be standard or fast")
	}
	return options, nil
}

func validateOptions(o codex.LaunchOptions, c codex.ModelCatalog) error {
	check := o
	// Standard speed is always available. Fast must be in the selected account catalog.
	if check.Speed == "standard" {
		check.Speed = ""
	}
	return check.Validate(c)
}

func modelIDs(c codex.ModelCatalog) []object {
	result := []object{}
	for _, model := range c.Models {
		if model.Hidden {
			continue
		}
		for _, effort := range model.Efforts {
			for _, speed := range []string{"standard", "fast"} {
				options := codex.LaunchOptions{Model: model.Model, Effort: effort.Effort, Speed: speed}
				if validateOptions(options, c) != nil {
					continue
				}
				result = append(result, object{"id": fmt.Sprintf("%s@%s@%s", model.Model, effort.Effort, speed), "object": "model", "owned_by": "cab"})
			}
		}
	}
	return result
}

func cachedModels(read func(string) (codex.ModelCatalog, error)) func(string) (codex.ModelCatalog, error) {
	var mu sync.Mutex
	type entry struct {
		catalog codex.ModelCatalog
		until   time.Time
	}
	entries := map[string]entry{}
	return func(home string) (codex.ModelCatalog, error) {
		mu.Lock()
		defer mu.Unlock()
		if e, ok := entries[home]; ok && time.Now().Before(e.until) {
			return e.catalog, nil
		}
		catalog, err := read(home)
		if err == nil {
			entries[home] = entry{catalog, time.Now().Add(30 * time.Second)}
		}
		return catalog, err
	}
}
