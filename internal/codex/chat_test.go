package codex

import "testing"

func TestChatEventsExposePublicSummariesAndMessages(t *testing.T) {
	cases := []struct {
		event  string
		answer bool
		kind   string
	}{
		{`{"type":"item.completed","item":{"type":"reasoning","text":"Checking the supplied numbers."}}`, false, "reasoning"},
		{`{"type":"item.completed","item":{"type":"agent_message","text":"42"}}`, true, "content"},
		{`{"type":"item.completed","item":{"type":"agent_message","text":"{\"tool\":\"lookup\"}"}}`, false, ""},
		{`{"type":"item.completed","item":{"type":"reasoning_raw_content","text":"private"}}`, true, ""},
		{`{"type":"error","message":"private diagnostics"}`, true, ""},
	}
	for _, c := range cases {
		if e := readChatEvent([]byte(c.event), c.answer); e.Kind != c.kind {
			t.Errorf("got %q want %q", e.Kind, c.kind)
		}
	}
}
