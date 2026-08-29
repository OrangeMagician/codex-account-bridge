package codex

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/url"
	"os"
	"os/exec"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"
)

type appServerMessage struct {
	ID     json.RawMessage `json:"id"`
	Method string          `json:"method"`
	Result json.RawMessage `json:"result"`
	Params json.RawMessage `json:"params"`
	Error  *struct {
		Code    int    `json:"code"`
		Message string `json:"message"`
	} `json:"error"`
}

type browserLoginStart struct {
	Type    string `json:"type"`
	LoginID string `json:"loginId"`
	AuthURL string `json:"authUrl"`
}

type browserLoginCompleted struct {
	LoginID string  `json:"loginId"`
	Success bool    `json:"success"`
	Error   *string `json:"error"`
}

// RunBrowserLogin uses the official Codex app-server browser flow. The app-server
// owns PKCE, the localhost callback, credential persistence, and token refresh;
// CAB only prints the allowlisted authorization URL for its UI to open.
func RunBrowserLogin(home string) (int, error) {
	binary, err := FindReal("codex")
	if err != nil {
		return 127, err
	}
	cmd := exec.Command(binary, "app-server")
	cmd.Env = environment(home)
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return 1, err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return 1, err
	}
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		return 127, err
	}

	stop := func() {
		_ = stdin.Close()
		if cmd.Process != nil {
			_ = cmd.Process.Signal(syscall.SIGTERM)
		}
		wait := make(chan error, 1)
		go func() { wait <- cmd.Wait() }()
		select {
		case <-wait:
		case <-time.After(2 * time.Second):
			if cmd.Process != nil {
				_ = cmd.Process.Kill()
			}
			<-wait
		}
	}

	signals := make(chan os.Signal, 1)
	signal.Notify(signals, os.Interrupt, syscall.SIGTERM, syscall.SIGHUP)
	defer signal.Stop(signals)
	interrupted := make(chan struct{})
	go func() {
		select {
		case sig := <-signals:
			if cmd.Process != nil {
				_ = cmd.Process.Signal(sig)
			}
		case <-interrupted:
		}
	}()
	defer close(interrupted)

	encoder := json.NewEncoder(stdin)
	decoder := json.NewDecoder(stdout)
	if err := encoder.Encode(map[string]any{
		"method": "initialize",
		"id":     1,
		"params": map[string]any{
			"clientInfo": map[string]string{
				"name": "codex_account_bridge", "title": "CodexAccountBridge", "version": "1.0",
			},
		},
	}); err != nil {
		stop()
		return 1, err
	}
	if _, err := readResponse(decoder, 1); err != nil {
		stop()
		return 1, fmt.Errorf("initialize official Codex app-server: %w", err)
	}
	if err := encoder.Encode(map[string]any{"method": "initialized", "params": map[string]any{}}); err != nil {
		stop()
		return 1, err
	}
	if err := encoder.Encode(map[string]any{
		"method": "account/login/start", "id": 2, "params": map[string]string{"type": "chatgpt"},
	}); err != nil {
		stop()
		return 1, err
	}
	response, err := readResponse(decoder, 2)
	if err != nil {
		stop()
		return 1, fmt.Errorf("start official ChatGPT browser login: %w", err)
	}
	var login browserLoginStart
	if err := json.Unmarshal(response.Result, &login); err != nil {
		stop()
		return 1, fmt.Errorf("decode browser login response: %w", err)
	}
	if login.Type != "chatgpt" || login.LoginID == "" {
		stop()
		return 1, errors.New("official Codex app-server returned an unexpected login response")
	}
	if err := validateBrowserAuthURL(login.AuthURL); err != nil {
		stop()
		return 1, err
	}
	fmt.Printf("Open this official ChatGPT login URL in the selected browser:\n%s\n", login.AuthURL)

	for {
		var message appServerMessage
		if err := decoder.Decode(&message); err != nil {
			stop()
			if errors.Is(err, io.EOF) {
				return 1, errors.New("official Codex app-server exited before login completed")
			}
			return 1, err
		}
		if message.Method != "account/login/completed" {
			continue
		}
		var completed browserLoginCompleted
		if err := json.Unmarshal(message.Params, &completed); err != nil || completed.LoginID != login.LoginID {
			continue
		}
		stop()
		if !completed.Success {
			if completed.Error != nil && strings.TrimSpace(*completed.Error) != "" {
				return 1, errors.New(strings.TrimSpace(*completed.Error))
			}
			return 1, errors.New("ChatGPT browser login was cancelled")
		}
		fmt.Println("ChatGPT browser login completed.")
		return 0, nil
	}
}

func readResponse(decoder *json.Decoder, id int) (appServerMessage, error) {
	want := strconv.Itoa(id)
	for {
		var message appServerMessage
		if err := decoder.Decode(&message); err != nil {
			return appServerMessage{}, err
		}
		if string(message.ID) != want {
			continue
		}
		if message.Error != nil {
			return appServerMessage{}, fmt.Errorf("app-server error %d: %s", message.Error.Code, message.Error.Message)
		}
		return message, nil
	}
}

func validateBrowserAuthURL(raw string) error {
	if len(raw) == 0 || len(raw) > 32*1024 {
		return errors.New("official Codex app-server returned an invalid authorization URL length")
	}
	authURL, err := url.Parse(raw)
	if err != nil || authURL.Scheme != "https" || !officialAuthHost(authURL.Hostname()) {
		return errors.New("official Codex app-server returned a non-OpenAI authorization URL")
	}
	redirectURL, err := url.Parse(authURL.Query().Get("redirect_uri"))
	if err != nil || redirectURL.Scheme != "http" || redirectURL.Hostname() != "localhost" || redirectURL.Path != "/auth/callback" {
		return errors.New("official Codex app-server returned an unexpected callback URL")
	}
	port, err := strconv.Atoi(redirectURL.Port())
	if err != nil || (port != 1455 && port != 1457) {
		return errors.New("official Codex app-server returned an invalid callback port")
	}
	return nil
}

func officialAuthHost(host string) bool {
	host = strings.ToLower(host)
	return host == "openai.com" || strings.HasSuffix(host, ".openai.com") || host == "chatgpt.com" || strings.HasSuffix(host, ".chatgpt.com")
}
