package codex

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// Chat runs an ephemeral, isolated inference request. Credentials are managed
// by the official executable in the explicitly selected home.
func Chat(ctx context.Context, home, prompt, schema string, options LaunchOptions, emit func(ChatEvent) error) (string, error) {
	binary, err := FindReal("codex")
	if err != nil {
		return "", err
	}
	dir, err := os.MkdirTemp("", "cab-api-")
	if err != nil {
		return "", err
	}
	defer os.RemoveAll(dir)
	if err = initProbeRepository(dir); err != nil {
		return "", err
	}
	result := filepath.Join(dir, "result")
	args := []string{"exec", "--json", "--ephemeral", "--ignore-user-config", "--cd", dir, "--output-last-message", result,
		"-c", `default_permissions="cab-chat"`, "-c", `permissions.cab-chat={filesystem={":root"="deny",":workspace_roots"="read"},network={enabled=false}}`,
		"-c", `shell_environment_policy.inherit="none"`,
		"-c", `forced_login_method="chatgpt"`, "-c", `web_search="disabled"`, "-c", "project_doc_max_bytes=0",
		"-c", "skills.include_instructions=false", "-c", `model_reasoning_summary="detailed"`}
	if options.Model == "" || options.Effort == "" || (options.Speed != "standard" && options.Speed != "fast") {
		return "", errors.New("explicit model, reasoning effort and speed are required")
	}
	tier := "default"
	if options.Speed == "fast" {
		tier = "priority"
	}
	args = append(args, "--model", options.Model, "-c", fmt.Sprintf("model_reasoning_effort=%q", options.Effort), "-c", fmt.Sprintf("service_tier=%q", tier))

	for _, feature := range []string{"shell_tool", "unified_exec", "plugins", "apps", "hooks", "multi_agent", "multi_agent_v2", "browser_use", "computer_use", "code_mode", "code_mode_host", "view_image", "image_generation", "skill_search", "memories"} {
		args = append(args, "--disable", feature)
	}
	if schema != "" {
		path := filepath.Join(dir, "output-schema.json")
		if err := os.WriteFile(path, []byte(schema), 0600); err != nil {
			return "", err
		}
		args = append(args, "--output-schema", path)
	}
	cmd := exec.CommandContext(ctx, binary, append(args, "-")...)
	cmd.Dir = dir
	// Do not pass unrelated API keys, session ids or provider overrides from the launching shell.
	for _, key := range []string{"HOME", "USER", "PATH", "TMPDIR", "LANG", "SSL_CERT_FILE", "SSL_CERT_DIR", "HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY"} {
		if value, ok := os.LookupEnv(key); ok {
			cmd.Env = append(cmd.Env, key+"="+value)
		}
	}
	cmd.Env = append(cmd.Env, "CODEX_HOME="+home)
	cmd.Stdin = strings.NewReader(prompt)
	out, err := cmd.StdoutPipe()
	if err != nil {
		return "", err
	}
	stderr := cappedBuffer{limit: 8192}
	cmd.Stderr = &stderr
	if err := cmd.Start(); err != nil {
		return "", errors.New("could not start official Codex")
	}
	scan := bufio.NewScanner(out)
	scan.Buffer(make([]byte, 64<<10), 4<<20)
	var eventErr error
	for scan.Scan() {
		event := readChatEvent(scan.Bytes(), schema == "")
		if event.Kind != "" && emit != nil {
			if eventErr = emit(event); eventErr != nil {
				_ = cmd.Process.Kill()
				break
			}
		}
	}
	if scan.Err() != nil {
		_ = cmd.Process.Kill()
		eventErr = errors.New("invalid Codex event stream")
	}
	runErr := cmd.Wait()
	if eventErr != nil {
		return "", eventErr
	}
	if err := runErr; err != nil {
		if ctx.Err() != nil {
			return "", ctx.Err()
		}
		return "", fmt.Errorf("Codex: %s", usageProbeFailureCategory(stderr.String()))
	}
	file, err := os.Open(result)
	if err != nil {
		return "", errors.New("Codex returned no answer")
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, (4<<20)+1))
	if err != nil || len(data) > 4<<20 || len(data) == 0 {
		return "", errors.New("invalid Codex answer")
	}
	return strings.TrimSpace(string(data)), nil
}

// CLI reasoning items contain the model's public reasoning summaries.
// Raw reasoning, stderr and authentication diagnostics are never forwarded.
type ChatEvent struct {
	Kind string
	Text string
}

func readChatEvent(data []byte, includeAnswer bool) ChatEvent {
	var event struct {
		Type string
		Item struct {
			Type string
			Text string
		}
	}
	if json.Unmarshal(data, &event) != nil || event.Type != "item.completed" || event.Item.Text == "" {
		return ChatEvent{}
	}
	switch event.Item.Type {
	case "reasoning":
		return ChatEvent{Kind: "reasoning", Text: event.Item.Text}
	case "agent_message":
		if includeAnswer {
			return ChatEvent{Kind: "content", Text: event.Item.Text}
		}
	}
	return ChatEvent{}
}
