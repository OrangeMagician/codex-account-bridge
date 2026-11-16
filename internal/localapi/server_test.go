package localapi

import (
	"context"
	"encoding/json"
	"net/http/httptest"
	"net/netip"
	"path/filepath"
	"strings"
	"testing"

	"github.com/OrangeMagician/codex-account-bridge/internal/codex"
	"github.com/OrangeMagician/codex-account-bridge/internal/config"
)

func TestAccountSelectionAndAdmission(t *testing.T) {
	root := t.TempDir()
	p := config.Paths{ConfigDir: filepath.Join(root, "config"), DataDir: filepath.Join(root, "data"), File: filepath.Join(root, "config", "config.json")}
	cfg := config.Empty()
	cfg.Accounts = []config.Account{{Name: "first", Home: filepath.Join(root, "a")}, {Name: "second", Home: filepath.Join(root, "b")}}
	cfg.DefaultAccount = "first"
	if err := config.Save(p, cfg); err != nil {
		t.Fatal(err)
	}
	selectAccount := func(name string) {
		t.Helper()
		if err := config.SelectAPIAccount(p, name); err != nil {
			t.Fatal(err)
		}
	}
	selectAccount("first")
	s, err := config.ReadAPISettings(p)
	if err != nil {
		t.Fatal(err)
	}
	var homes []string
	h := handler(p, netip.MustParseAddr("192.168.1.13"), s.Key, func(ctx context.Context, home, prompt, schema string, options codex.LaunchOptions, emit func(codex.ChatEvent) error) (string, error) {
		if !strings.Contains(prompt, "Question") || !strings.Contains(prompt, "Earlier answer") {
			t.Fatal("lost conversation")
		}
		homes = append(homes, home)
		if options.Model != "test-model" || options.Effort != "high" || options.Speed != "fast" {
			t.Fatal("incorrect inference settings", options)
		}
		return "Answer", nil
	}, func(string) (codex.ModelCatalog, error) { return testCatalog(), nil })
	query := func(peer, key string) int {
		req := httptest.NewRequest("POST", "/v1/chat/completions", strings.NewReader(`{"model":"test-model@high@fast","messages":[{"role":"assistant","content":"Earlier answer"},{"role":"user","content":"Question"}]}`))
		req.RemoteAddr = peer + ":5678"
		req.Header.Set("Authorization", "Bearer "+key)
		w := httptest.NewRecorder()
		h.ServeHTTP(w, req)
		return w.Code
	}
	if query("192.168.1.13", "wrong") != 401 || query("192.168.1.14", s.Key) != 403 || query("192.168.1.13", s.Key) != 200 {
		t.Fatal("unexpected access decision")
	}
	selectAccount("second")
	if query("192.168.1.13", s.Key) != 200 || len(homes) != 2 || homes[0] != cfg.Accounts[0].Home || homes[1] != cfg.Accounts[1].Home {
		t.Fatalf("incorrect account routing: %v", homes)
	}
	cfg.Remove("second")
	if err := config.Save(p, cfg); err != nil {
		t.Fatal(err)
	}
	if query("192.168.1.13", s.Key) != 503 || len(homes) != 2 {
		t.Fatal("removed account fell back")
	}
}

func TestClientToolsAndStream(t *testing.T) {
	var r chatRequest
	err := json.Unmarshal([]byte(`{"messages":[{"role":"user","content":[{"type":"text","text":"Check"}]}],"tools":[{"type":"function","function":{"name":"lookup","parameters":{"type":"object"}}}]}`), &r)
	if err != nil {
		t.Fatal(err)
	}
	prompt, schema, err := r.prepare()
	if err != nil || schema == "" || !strings.Contains(prompt, "lookup") {
		t.Fatal("missing tool schema")
	}
	message, finish, err := r.answer(`{"content":"","tool":"lookup","arguments":"{}"}`, true)
	if err != nil || finish != "tool_calls" {
		t.Fatal("invalid tool response", err)
	}
	w := httptest.NewRecorder()
	writeCompletion(w, true, message, finish, "test-model@high@fast")
	if !strings.Contains(w.Body.String(), `"index":0`) || !strings.HasSuffix(w.Body.String(), "data: [DONE]\n\n") {
		t.Fatal("invalid stream")
	}
	if _, _, err = r.answer(`{"tool":"unknown","arguments":"{}"}`, true); err == nil {
		t.Fatal("accepted unknown function")
	}
	if CheckNetwork("0.0.0.0:8787", "192.168.1.13") == nil || CheckNetwork("127.0.0.1:8787", "0.0.0.0") == nil {
		t.Fatal("accepted wildcard")
	}
}

func testCatalog() codex.ModelCatalog {
	return codex.ModelCatalog{Models: []codex.AvailableModel{{Model: "test-model", Efforts: []codex.ReasoningOption{{Effort: "low"}, {Effort: "high"}}, ServiceTiers: []codex.ServiceTier{{ID: "priority"}}}}}
}

func TestExplicitInferenceChoices(t *testing.T) {
	for _, id := range []string{"", "cab-codex", "test-model@high@turbo", "test-model@high@fast@extra"} {
		if _, err := (chatRequest{Model: id}).launchOptions(); err == nil {
			t.Errorf("accepted incomplete ID %q", id)
		}
	}
	for _, id := range []string{"test-model", "test-model@high"} {
		options, err := (chatRequest{Model: id}).launchOptions()
		if err != nil || options.Speed != "standard" || (id == "test-model" && options.Effort != "medium") {
			t.Fatal("omitted fast must use standard", options, err)
		}
	}

	optionsFast, errFast := (chatRequest{Model: "test-model@fast"}).launchOptions()
	if errFast != nil || optionsFast.Effort != "medium" || optionsFast.Speed != "fast" {
		t.Fatal("fast shorthand failed")
	}
	for _, speed := range []string{"standard", "fast"} {
		options, err := (chatRequest{Model: "test-model@high@" + speed}).launchOptions()
		if err != nil || validateOptions(options, testCatalog()) != nil {
			t.Fatal("valid combination rejected", err)
		}
	}
	if _, err := (chatRequest{Model: "test-model@high@fast", ReasoningEffort: "low"}).launchOptions(); err == nil {
		t.Fatal("accepted conflicting effort")
	}
	options, err := (chatRequest{Model: "test-model", ReasoningEffort: "high", ServiceTier: "priority"}).launchOptions()
	if err != nil || options.Speed != "fast" {
		t.Fatal("standard API parameters rejected")
	}
	if validateOptions(codex.LaunchOptions{Model: "missing", Effort: "high", Speed: "standard"}, testCatalog()) == nil {
		t.Fatal("unavailable model accepted")
	}
	c := testCatalog()
	c.Models[0].ServiceTiers = nil
	if validateOptions(codex.LaunchOptions{Model: "test-model", Effort: "high", Speed: "fast"}, c) == nil {
		t.Fatal("unsupported speed accepted")
	}
	ids := modelIDs(testCatalog())
	if len(ids) != 4 {
		t.Fatal("missing model combinations", ids)
	}
}
