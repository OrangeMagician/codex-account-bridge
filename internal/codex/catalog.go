package codex

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os/exec"
	"strings"
	"time"
)

// These calls use a separate stdio server in exactly one selected CODEX_HOME.
// Its runtime status says nothing about a thread loaded in another server.
type catalogClient struct {
	cmd     *exec.Cmd
	in      io.WriteCloser
	encoder *json.Encoder
	decoder *json.Decoder
	id      int
}

func openCatalog(ctx context.Context, home string) (*catalogClient, error) {
	binary, err := FindReal("codex")
	if err != nil {
		return nil, err
	}
	cmd := exec.CommandContext(ctx, binary, "app-server")
	cmd.Env = environment(home)
	in, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	out, err := cmd.StdoutPipe()
	if err != nil {
		_ = in.Close()
		return nil, err
	}
	// Do not forward unsolicited server logs or authentication diagnostics.
	cmd.Stderr = io.Discard
	if err = cmd.Start(); err != nil {
		_ = in.Close()
		return nil, err
	}
	c := &catalogClient{cmd: cmd, in: in, encoder: json.NewEncoder(in), decoder: json.NewDecoder(io.LimitReader(out, 16<<20))}
	var initialized struct{}
	if err = c.call("initialize", map[string]any{"clientInfo": map[string]string{"name": "codex_account_bridge", "version": "1"}}, &initialized); err != nil {
		c.close()
		return nil, err
	}
	if err = c.encoder.Encode(map[string]any{"method": "initialized", "params": map[string]any{}}); err != nil {
		c.close()
		return nil, err
	}
	return c, nil
}

func (c *catalogClient) close() { stopUsageAppServer(c.cmd, c.in) }

func (c *catalogClient) call(method string, params any, result any) error {
	c.id++
	if err := c.encoder.Encode(map[string]any{"method": method, "id": c.id, "params": params}); err != nil {
		return fmt.Errorf("%s: connection closed", method)
	}
	for {
		var message appServerMessage
		if err := c.decoder.Decode(&message); err != nil {
			return fmt.Errorf("%s: server response unavailable (update Codex if unsupported)", method)
		}
		if string(message.ID) != fmt.Sprint(c.id) {
			continue
		}
		if message.Error != nil {
			return fmt.Errorf("%s: official server rejected the request (code %d); check client support and account access", method, message.Error.Code)
		}
		if len(message.Result) == 0 || string(message.Result) == "null" {
			return fmt.Errorf("%s: missing result", method)
		}
		if err := json.Unmarshal(message.Result, result); err != nil {
			return fmt.Errorf("%s: incompatible response", method)
		}
		return nil
	}
}

type ReasoningOption struct {
	Effort      string `json:"reasoningEffort"`
	Description string `json:"description"`
}
type ServiceTier struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	Description string `json:"description"`
}
type AvailableModel struct {
	ID                   string            `json:"id"`
	Model                string            `json:"model"`
	DisplayName          string            `json:"displayName"`
	Description          string            `json:"description"`
	Hidden               bool              `json:"hidden"`
	IsDefault            bool              `json:"isDefault"`
	DefaultEffort        string            `json:"defaultReasoningEffort"`
	Efforts              []ReasoningOption `json:"supportedReasoningEfforts"`
	ServiceTiers         []ServiceTier     `json:"serviceTiers"`
	AdditionalSpeedTiers []string          `json:"additionalSpeedTiers,omitempty"`
	Upgrade              *string           `json:"upgrade,omitempty"`
}
type ModelCatalog struct {
	Models    []AvailableModel `json:"models"`
	FetchedAt time.Time        `json:"fetched_at"`
	Scope     string           `json:"scope"`
}

func ReadModels(home string) (ModelCatalog, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	c, err := openCatalog(ctx, home)
	if err != nil {
		return ModelCatalog{}, err
	}
	defer c.close()
	result := ModelCatalog{Models: []AvailableModel{}, FetchedAt: time.Now().UTC(), Scope: "selected_account_catalog_not_verified_entitlement"}
	cursor := ""
	seen := map[string]bool{}
	for page := 0; page < 50; page++ {
		var response struct {
			Data       []AvailableModel `json:"data"`
			NextCursor *string          `json:"nextCursor"`
		}
		params := map[string]any{"limit": 100, "includeHidden": false}
		if cursor != "" {
			params["cursor"] = cursor
		}
		if err := c.call("model/list", params, &response); err != nil {
			return ModelCatalog{}, err
		}
		for _, m := range response.Data {
			if !m.Hidden && m.Model != "" {
				result.Models = append(result.Models, m)
			}
		}
		if response.NextCursor == nil || *response.NextCursor == "" {
			return result, nil
		}
		cursor = *response.NextCursor
		if seen[cursor] {
			return ModelCatalog{}, errors.New("model/list: repeated pagination cursor")
		}
		seen[cursor] = true
	}
	return ModelCatalog{}, errors.New("model/list: catalog exceeds pagination limit")
}

type LaunchOptions struct{ Model, Effort, Speed, Resume string }

func (o LaunchOptions) Validate(catalog ModelCatalog) error {
	if o.Model == "" && o.Effort == "" && o.Speed == "" {
		return nil
	}
	if o.Model == "" {
		return errors.New("choose an explicit model before overriding reasoning or speed; the configured default may differ from the catalog recommendation")
	}
	var chosen *AvailableModel
	for i := range catalog.Models {
		m := &catalog.Models[i]
		if m.Model == o.Model {
			chosen = m
			break
		}
	}
	if chosen == nil {
		return errors.New("selected model is absent from this account's current catalog; choose an available model")
	}
	if o.Effort != "" {
		found := false
		for _, e := range chosen.Efforts {
			found = found || e.Effort == o.Effort
		}
		if !found {
			return errors.New("reasoning effort is not supported by the selected model")
		}
	}
	if o.Speed != "" {
		if o.Speed != "standard" && o.Speed != "fast" && o.Speed != "ultrafast" {
			return errors.New("speed must be standard, fast or ultrafast")
		}
		found := false
		for _, s := range chosen.ServiceTiers {
			found = found || s.ID == o.Speed || (o.Speed == "fast" && s.ID == "priority")
		}
		for _, s := range chosen.AdditionalSpeedTiers {
			found = found || s == o.Speed
		}
		if !found {
			return errors.New("speed tier is not advertised by this model; use the official default")
		}
	}
	return nil
}

func (o LaunchOptions) Arguments() []string {
	args := []string{}
	if o.Model != "" {
		args = append(args, "--model", o.Model)
	}
	if o.Effort != "" {
		value, _ := json.Marshal(o.Effort)
		args = append(args, "-c", "model_reasoning_effort="+string(value))
	}
	if o.Speed != "" {
		value, _ := json.Marshal(o.Speed)
		args = append(args, "-c", "service_tier="+string(value))
	}
	return args
}

type StoredTask struct {
	ID        string  `json:"id"`
	Name      *string `json:"name"`
	CWD       string  `json:"cwd"`
	UpdatedAt int64   `json:"updatedAt"`
	Pinned    *bool   `json:"isPinned"`
}
type TaskPage struct {
	Tasks      []StoredTask `json:"tasks"`
	NextCursor *string      `json:"next_cursor"`
	Scope      string       `json:"scope"`
}
type TaskFilter struct {
	Cursor, Search, Directory string
	Archived                  bool
	PinnedOnly                bool
}

func ReadTasks(home string, filter TaskFilter) (TaskPage, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	c, err := openCatalog(ctx, home)
	if err != nil {
		return TaskPage{}, err
	}
	defer c.close()
	params := map[string]any{"limit": 50, "sortKey": "updated_at", "archived": filter.Archived, "sourceKinds": []string{"cli", "vscode", "exec", "appServer"}, "useStateDbOnly": true}
	if filter.Cursor != "" {
		params["cursor"] = filter.Cursor
	}
	if filter.Search != "" {
		params["searchTerm"] = filter.Search
	}
	if filter.Directory != "" {
		params["cwd"] = filter.Directory
	}
	if filter.PinnedOnly {
		params["isPinned"] = true
	}
	var response struct {
		Data       []StoredTask `json:"data"`
		NextCursor *string      `json:"nextCursor"`
	}
	if err = c.call("thread/list", params, &response); err != nil {
		return TaskPage{}, err
	}
	if response.Data == nil {
		response.Data = []StoredTask{}
	}
	if filter.PinnedOnly {
		for _, task := range response.Data {
			if task.Pinned == nil || !*task.Pinned {
				return TaskPage{}, errors.New("task pin filtering is unsupported by this Codex version")
			}
		}
	}
	return TaskPage{Tasks: response.Data, NextCursor: response.NextCursor, Scope: "stored_history_not_live_runtime"}, nil
}

func SetTaskPinned(home, id string, pinned bool) error {
	if err := ValidateTaskID(id); err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	c, err := openCatalog(ctx, home)
	if err != nil {
		return err
	}
	defer c.close()
	var response struct {
		Thread StoredTask `json:"thread"`
	}
	if err = c.call("thread/metadata/update", map[string]any{"threadId": id, "isPinned": pinned}, &response); err != nil {
		return err
	}
	if response.Thread.Pinned == nil || *response.Thread.Pinned != pinned {
		return errors.New("task pinning is unsupported by this Codex version; update Codex")
	}
	return nil
}

func ValidateTaskID(id string) error {
	if len(id) < 1 || len(id) > 200 || strings.ContainsAny(id, "/\\\x00\r\n \t") || strings.HasPrefix(id, "-") {
		return errors.New("invalid task ID")
	}
	return nil
}
