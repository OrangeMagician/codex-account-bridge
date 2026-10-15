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
