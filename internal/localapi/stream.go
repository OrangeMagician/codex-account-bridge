package localapi

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"time"

	"github.com/OrangeMagician/codex-account-bridge/internal/codex"
)

type chatResult struct {
	answer string
	err    error
}
type streamUpdate struct {
	event  codex.ChatEvent
	result *chatResult
}

// Only this handler goroutine writes to the response. Worker events, keepalives,
// errors and the terminal chunk share one SSE connection and completion ID.
func serveChatStream(w http.ResponseWriter, parent context.Context, req chatRequest, run func(func(codex.ChatEvent) error) (string, error)) {
	ctx, cancel := context.WithCancel(parent)
	defer cancel()
	updates := make(chan streamUpdate, 8)
	send := func(u streamUpdate) error {
		select {
		case updates <- u:
			return nil
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	go func() {
		answer, err := run(func(event codex.ChatEvent) error { return send(streamUpdate{event: event}) })
		_ = send(streamUpdate{result: &chatResult{answer, err}})
	}()
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("X-Accel-Buffering", "no")
	controller := http.NewResponseController(w)
	id, created := identifier("chatcmpl-"), time.Now().Unix()
	frame := func(delta object, finish any) error {
		data, err := json.Marshal(object{"id": id, "object": "chat.completion.chunk", "created": created, "model": req.Model, "choices": []object{{"index": 0, "delta": delta, "finish_reason": finish}}})
		if err != nil {
			return err
		}
		if _, err = fmt.Fprintf(w, "data: %s\n\n", data); err != nil {
			return err
		}
		return controller.Flush()
	}
	fail := func(err error) {
		data, _ := json.Marshal(object{"error": object{"message": err.Error(), "type": "cab_error", "code": "inference_failed"}})
		fmt.Fprintf(w, "data: %s\n\ndata: [DONE]\n\n", data)
		_ = controller.Flush()
	}
	if frame(object{"role": "assistant"}, nil) != nil {
		return
	}
	ticker := time.NewTicker(10 * time.Second)
	defer ticker.Stop()
	var delivered strings.Builder
	for {
		select {
		case <-ctx.Done():
			fail(ctx.Err())
			return
		case <-ticker.C:
			if _, err := fmt.Fprint(w, ": keep-alive\n\n"); err != nil {
				return
			}
			if controller.Flush() != nil {
				return
			}
		case u := <-updates:
			if u.result == nil {
				switch u.event.Kind {
				case "reasoning":
					if frame(object{"reasoning_content": u.event.Text}, nil) != nil {
						return
					}
				case "content":
					// Structured tool envelopes must be parsed before they reach the client.
					if len(req.Tools) == 0 || string(req.ToolChoice) == `"none"` {
						if frame(object{"content": u.event.Text}, nil) != nil {
							return
						}
						delivered.WriteString(u.event.Text)
					}
				}
				continue
			}
			if u.result.err != nil {
				fail(u.result.err)
				return
			}
			message, finish, err := req.answer(u.result.answer, len(req.Tools) > 0 && string(req.ToolChoice) != `"none"`)
			if err != nil {
				fail(err)
				return
			}
			if delivered.Len() > 0 {
				message["content"] = ""
			}
			if calls, ok := message["tool_calls"].([]object); ok {
				for i := range calls {
					calls[i]["index"] = i
				}
			}
			if frame(message, nil) != nil {
				return
			}
			if frame(object{}, finish) != nil {
				return
			}
			fmt.Fprint(w, "data: [DONE]\n\n")
			_ = controller.Flush()
			return
		}
	}
}
