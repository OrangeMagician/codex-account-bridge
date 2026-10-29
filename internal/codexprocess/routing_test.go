package codexprocess

import "testing"

func TestRouteProjectionUsesOnlyExplicitHomeAndRole(t *testing.T) {
	r := routeFromLaunchData([]string{"codex", "app-server"}, []string{"SECRET=do-not-expose", "CODEX_HOME=/accounts/work"}, "/default")
	if !r.Verified || r.Home != "/accounts/work" || r.Role != "app-server" {
		t.Fatal(r)
	}
	if routeFromLaunchData(nil, []string{"CODEX_HOME=relative"}, "/default").Verified {
		t.Fatal("relative home accepted")
	}
	r = routeFromLaunchData([]string{"codex"}, nil, "/default")
	if r.Home != "/default" || !r.Verified {
		t.Fatal(r)
	}
}

func TestDesktopRouteRequiresPersistentAppServerTransport(t *testing.T) {
	for _, test := range []struct {
		args    []string
		desktop bool
	}{
		{[]string{"codex", "app-server", "--listen", "ws://127.0.0.1:1234"}, true},
		{[]string{"codex", "app-server", "--listen=wss://localhost:1234"}, true},
		{[]string{"codex", "app-server", "--listen", "unix:///tmp/desktop.sock"}, true},
		{[]string{"codex", "app-server"}, false},
		{[]string{"codex", "app-server", "--listen", "stdio://"}, false},
		{[]string{"codex", "--listen", "ws://localhost:1234"}, false},
	} {
		route := routeFromLaunchData(test.args, []string{"CODEX_HOME=/accounts/work"}, "/default")
		if route.Desktop != test.desktop {
			t.Fatalf("args %v: desktop = %t", test.args, route.Desktop)
		}
	}
}
