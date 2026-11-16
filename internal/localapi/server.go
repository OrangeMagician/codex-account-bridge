package localapi

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/netip"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"github.com/OrangeMagician/codex-account-bridge/internal/codex"
	"github.com/OrangeMagician/codex-account-bridge/internal/config"
)

const Model = "MODEL@EFFORT@SPEED"

type object = map[string]any

func CheckNetwork(listen, client string) error {
	addr, err := netip.ParseAddrPort(listen)
	if err != nil || addr.Port() == 0 || !(addr.Addr().IsLoopback() || addr.Addr().IsPrivate()) {
		return errors.New("listen must be a specific loopback or private IP and port")
	}
	peer, err := netip.ParseAddr(client)
	if err != nil || !(peer.IsLoopback() || peer.IsPrivate()) {
		return errors.New("choose a specific private or loopback client IP")
	}
	return nil
}

func Serve(paths config.Paths, listen, client string) error {
	if err := CheckNetwork(listen, client); err != nil {
		return err
	}
	settings, err := config.ReadAPISettings(paths)
	if err != nil {
		return err
	}
	if settings.Key == "" {
		return errors.New("select an API account first")
	}
	listener, err := net.Listen("tcp", listen)
	if err != nil {
		return err
	}
	server := http.Server{Handler: handler(paths, netip.MustParseAddr(client), settings.Key, codex.Chat, cachedModels(codex.ReadModels)), ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 30 * time.Second, WriteTimeout: 6 * time.Minute, IdleTimeout: 30 * time.Second, MaxHeaderBytes: 16 << 10}
	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer cancel()
	server.BaseContext = func(net.Listener) context.Context { return ctx }
	stopped := make(chan struct{})
	go func() {
		<-ctx.Done()
		drain, finish := context.WithTimeout(context.Background(), 3*time.Second)
		defer finish()
		_ = server.Shutdown(drain)
		close(stopped)
	}()
	err = server.Serve(listener)
	cancel()
	<-stopped
	if errors.Is(err, http.ErrServerClosed) {
		return nil
	}
	return err
}

type inference func(context.Context, string, string, string, codex.LaunchOptions, func(codex.ChatEvent) error) (string, error)

func handler(paths config.Paths, client netip.Addr, key string, chat inference, models func(string) (codex.ModelCatalog, error)) http.Handler {
	slots := make(chan struct{}, 2)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		peer, err := netip.ParseAddrPort(r.RemoteAddr)
		if err != nil || peer.Addr().Unmap() != client.Unmap() {
			apiError(w, 403, "Client address is not allowed")
			return
		}
		if key == "" || subtle.ConstantTimeCompare([]byte(r.Header.Get("Authorization")), []byte("Bearer "+key)) != 1 {
			apiError(w, 401, "Invalid CAB API key")
			return
		}
		w.Header().Set("Cache-Control", "no-store")
		var account config.Account
		_, err = config.ReadLocked(paths, func(cfg config.Config) error {
			settings, err := config.ReadAPISettings(paths)
			if err != nil {
				return err
			}
			var ok bool
			account, ok = cfg.Find(settings.Account)
			if !ok || account.Home != settings.Home || settings.Key != key {
				return errors.New("reselect the API account")
			}
			return nil
		})
		if err != nil {
			apiError(w, 503, "Select a registered account in CAB")
			return
		}
		if r.Method == "GET" && r.URL.Path == "/v1/models" {
			catalog, err := models(account.Home)
			if err != nil {
				apiError(w, 502, "Cannot read the selected account's model catalog")
				return
			}
			respond(w, 200, object{"object": "list", "data": modelIDs(catalog)})
			return
		}
		if r.Method != "POST" || r.URL.Path != "/v1/chat/completions" {
			apiError(w, 404, "Unsupported endpoint")
			return
		}
		var req chatRequest
		reader := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<20))
		if err := reader.Decode(&req); err != nil || reader.Decode(&struct{}{}) != io.EOF {
			apiError(w, 400, "Invalid or oversized chat request")
			return
		}
		options, err := req.launchOptions()
		if err != nil {
			apiError(w, 400, err.Error())
			return
		}
		prompt, schema, err := req.prepare()
		if err != nil {
			apiError(w, 400, err.Error())
			return
		}
		select {
		case slots <- struct{}{}:
			defer func() { <-slots }()
		default:
			apiError(w, 429, "CAB is processing other requests")
			return
		}
		catalog, err := models(account.Home)
		if err != nil {
			apiError(w, 502, "Cannot read the selected account's model catalog")
			return
		}
		if err = validateOptions(options, catalog); err != nil {
			apiError(w, 400, err.Error())
			return
		}
		ctx, cancel := context.WithTimeout(r.Context(), 5*time.Minute)
		defer cancel()
		if req.Stream {
			serveChatStream(w, ctx, req, func(emit func(codex.ChatEvent) error) (string, error) {
				return chat(ctx, account.Home, prompt, schema, options, emit)
			})
			return
		}
		answer, err := chat(ctx, account.Home, prompt, schema, options, nil)
		if err != nil {
			apiError(w, 502, err.Error())
			return
		}
		message, finish, err := req.answer(answer, schema != "")
		if err != nil {
			apiError(w, 502, err.Error())
			return
		}
		writeCompletion(w, req.Stream, message, finish, req.Model)
	})
}

type chatMessage struct {
	Role       string          `json:"role"`
	Content    json.RawMessage `json:"content"`
	ToolCalls  json.RawMessage `json:"tool_calls,omitempty"`
	ToolCallID string          `json:"tool_call_id,omitempty"`
	Name       string          `json:"name,omitempty"`
}
type functionSpec struct {
	Name        string          `json:"name"`
	Description string          `json:"description"`
	Parameters  json.RawMessage `json:"parameters"`
}
type toolSpec struct {
	Type     string       `json:"type"`
	Function functionSpec `json:"function"`
}
type chatRequest struct {
	Model           string          `json:"model"`
	ReasoningEffort string          `json:"reasoning_effort"`
	ServiceTier     string          `json:"service_tier"`
	Messages        []chatMessage   `json:"messages"`
	Stream          bool            `json:"stream"`
	Tools           []toolSpec      `json:"tools"`
	ToolChoice      json.RawMessage `json:"tool_choice"`
	N               int             `json:"n"`
}

const instructions = "Answer the latest user message in the supplied conversation. Preserve its language. The JSON contains the client's messages in chronological order, including instructions, earlier answers and any tool results. You have no local workspace or host tools. Never invent live data or tool results.\n"

func (r chatRequest) prepare() (string, string, error) {
	if len(r.Messages) == 0 || r.N < 0 || r.N > 1 {
		return "", "", errors.New("one chat completion and non-empty messages are required")
	}
	for _, m := range r.Messages {
		switch m.Role {
		case "system", "developer", "user", "assistant", "tool":
		default:
			return "", "", errors.New("unsupported message role")
		}
		var text string
		if len(m.Content) == 0 || string(m.Content) == "null" {
			if m.Role == "assistant" && len(m.ToolCalls) > 0 {
				continue
			}
			return "", "", errors.New("missing message content")
		}
		if json.Unmarshal(m.Content, &text) == nil {
			continue
		}
		var parts []struct {
			Type string
			Text string
		}
		if json.Unmarshal(m.Content, &parts) != nil {
			return "", "", errors.New("unsupported message content")
		}
		for _, p := range parts {
			if p.Type != "text" {
				return "", "", errors.New("CAB supports text content only")
			}
		}
	}
	messages, _ := json.Marshal(r.Messages)
	choice := string(r.ToolChoice)
	if choice == `"none"` || len(r.Tools) == 0 {
		return instructions + string(messages), "", nil
	}
	if choice != "" && choice != "null" && choice != `"auto"` {
		return "", "", errors.New("CAB supports auto or none tool choice")
	}
	names := make(map[string]bool)
	for _, t := range r.Tools {
		if t.Type != "function" || t.Function.Name == "" || names[t.Function.Name] {
			return "", "", errors.New("invalid client function")
		}
		names[t.Function.Name] = true
	}
	tools, _ := json.Marshal(r.Tools)
	const schema = `{"type":"object","additionalProperties":false,"required":["content","tool","arguments"],"properties":{"content":{"type":"string"},"tool":{"type":"string"},"arguments":{"type":"string"}}}`
	return instructions + "If you can answer directly, set content to your answer and tool and arguments to empty strings. If you need one of the client's functions, set tool to its exact name and arguments to a JSON object encoded as a string. The client executes it and returns its result in a later message. Client functions:\n" + string(tools) + "\nConversation:\n" + string(messages), schema, nil
}

func (r chatRequest) answer(answer string, structured bool) (object, string, error) {
	message := object{"role": "assistant", "content": answer}
	if !structured {
		return message, "stop", nil
	}
	var result struct{ Content, Tool, Arguments string }
	if json.Unmarshal([]byte(answer), &result) != nil {
		return nil, "", errors.New("invalid structured reply from Codex")
	}
	message["content"] = result.Content
	if result.Tool == "" && result.Content != "" {
		return message, "stop", nil
	}
	for _, tool := range r.Tools {
		if tool.Function.Name != result.Tool {
			continue
		}
		var args map[string]json.RawMessage
		if json.Unmarshal([]byte(result.Arguments), &args) != nil || args == nil {
			break
		}
		message["tool_calls"] = []object{{"id": identifier("call_"), "type": "function", "function": object{"name": result.Tool, "arguments": result.Arguments}}}
		return message, "tool_calls", nil
	}
	return nil, "", errors.New("Codex returned an invalid client function or empty answer")
}

func identifier(prefix string) string {
	var b [16]byte
	rand.Read(b[:])
	return prefix + hex.EncodeToString(b[:])
}

func writeCompletion(w http.ResponseWriter, stream bool, message object, finish string, model string) {
	frame := object{"id": identifier("chatcmpl-"), "created": time.Now().Unix(), "model": model}
	choice := object{"index": 0, "finish_reason": finish}
	frame["choices"] = []object{choice}
	if !stream {
		frame["object"] = "chat.completion"
		choice["message"] = message
		respond(w, 200, frame)
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	frame["object"] = "chat.completion.chunk"
	if calls, ok := message["tool_calls"].([]object); ok {
		for i := range calls {
			calls[i]["index"] = i
		}
	}
	choice["delta"] = message
	choice["finish_reason"] = nil
	data, _ := json.Marshal(frame)
	fmt.Fprintf(w, "data: %s\n\n", data)
	choice["delta"] = object{}
	choice["finish_reason"] = finish
	data, _ = json.Marshal(frame)
	fmt.Fprintf(w, "data: %s\n\ndata: [DONE]\n\n", data)
}

func respond(w http.ResponseWriter, status int, data any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(data)
}
func apiError(w http.ResponseWriter, status int, message string) {
	respond(w, status, object{"error": object{"message": message, "type": "cab_error", "code": strconv.Itoa(status)}})
}
