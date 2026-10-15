package codex

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"time"
)

// VerifyRemoteEntry starts the same public entry used by a new SSH connection.
// It does not force CODEX_HOME: doing so would conceal a broken account route.
// Only the initialized home and logged-in state are returned, never identity
// fields, credentials, prompts, or raw server output.
func VerifyRemoteEntry(expectedHome string) error {
	if !RemoteRoutingReady() {
		return fmt.Errorf("public Codex entry does not route through CAB")
	}
	entry, err := exec.LookPath("codex")
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, entry, "app-server")
	return verifyRemoteCommand(cmd, expectedHome)
}

func verifyRemoteCommand(cmd *exec.Cmd, expectedHome string) error {
	cmd.Env = os.Environ()
	in, err := cmd.StdinPipe()
	if err != nil {
		return err
	}
	out, err := cmd.StdoutPipe()
	if err != nil {
		_ = in.Close()
		return err
	}
	cmd.Stderr = io.Discard
	if err = cmd.Start(); err != nil {
		_ = in.Close()
		return err
	}
	client := &catalogClient{cmd: cmd, in: in, encoder: json.NewEncoder(in), decoder: json.NewDecoder(io.LimitReader(out, 1<<20))}
	defer client.close()
	var initialized struct {
		Home string `json:"codexHome"`
	}
	if err := client.call("initialize", map[string]any{"clientInfo": map[string]string{"name": "cab_remote_verification", "version": "1"}}, &initialized); err != nil {
		return err
	}
	if !filepath.IsAbs(initialized.Home) || filepath.Clean(initialized.Home) != filepath.Clean(expectedHome) {
		return fmt.Errorf("fresh Codex connection did not use the selected account home")
	}
	if err := client.encoder.Encode(map[string]any{"method": "initialized", "params": map[string]any{}}); err != nil {
		return err
	}
	var account rpcAccountRead
	if err := client.call("account/read", map[string]bool{"refreshToken": false}, &account); err != nil {
		return err
	}
	if account.Account == nil || account.Account.Type != "chatgpt" {
		return fmt.Errorf("fresh Codex connection is not signed in to ChatGPT")
	}
	return nil
}
