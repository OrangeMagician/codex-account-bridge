package localapi

import (
	"bufio"
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/OrangeMagician/codex-account-bridge/internal/codex"
)

func TestStreamArrivesBeforeInferenceCompletes(t *testing.T) {
	release := make(chan struct{})
	defer close(release)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		serveChatStream(w, r.Context(), chatRequest{Model: "test-model"}, func(emit func(codex.ChatEvent) error) (string, error) {
			if err := emit(codex.ChatEvent{Kind: "reasoning", Text: "Checking the supplied numbers."}); err != nil {
				return "", err
			}
			select {
			case <-release:
				return "42", nil
			case <-r.Context().Done():
				return "", r.Context().Err()
			}
		})
	}))
	defer server.Close()
	client := server.Client()
	client.Timeout = 2 * time.Second
	response, err := client.Get(server.URL)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	scan := bufio.NewScanner(response.Body)
	found := false
	for scan.Scan() {
		if strings.Contains(scan.Text(), `"reasoning_content":"Checking the supplied numbers."`) {
			found = true
			break
		}
	}
	if !found {
		t.Fatal("summary was buffered until completion", scan.Err())
	}
}

func TestStructuredStreamAndFailure(t *testing.T) {
	req := chatRequest{Model: "test", Tools: []toolSpec{{Type: "function", Function: functionSpec{Name: "lookup"}}}}
	w := httptest.NewRecorder()
	serveChatStream(w, context.Background(), req, func(emit func(codex.ChatEvent) error) (string, error) {
		_ = emit(codex.ChatEvent{Kind: "content", Text: "private envelope"})
		return `{"content":"","tool":"lookup","arguments":"{}"}`, nil
	})
	if strings.Contains(w.Body.String(), "private envelope") || !strings.Contains(w.Body.String(), `"finish_reason":"tool_calls"`) || !strings.HasSuffix(w.Body.String(), "data: [DONE]\n\n") {
		t.Fatal(w.Body.String())
	}
	w = httptest.NewRecorder()
	serveChatStream(w, context.Background(), chatRequest{Model: "test"}, func(func(codex.ChatEvent) error) (string, error) { return "", errors.New("Codex: rate_limited") })
	if !strings.Contains(w.Body.String(), `"error"`) || !strings.Contains(w.Body.String(), "rate_limited") || !strings.HasSuffix(w.Body.String(), "data: [DONE]\n\n") {
		t.Fatal(w.Body.String())
	}
}
