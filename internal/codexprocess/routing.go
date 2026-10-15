package codexprocess

import (
	"path/filepath"
	"strings"
)

// RouteDetails exposes only an account home and a process role, never arguments,
// environment values other than CODEX_HOME, credentials or task prompts.
type RouteDetails struct {
	Home     string `json:"home,omitempty"`
	Role     string `json:"role"`
	Verified bool   `json:"verified"`
}

func DescribeRoute(process Process, defaultHome string) RouteDetails {
	unknown := RouteDetails{Role: "unknown"}
	before, ok, err := inspect(process.PID)
	if err != nil || !ok || !sameIdentity(process, before) {
		return unknown
	}
	args, env, err := processLaunchData(process.PID)
	if err != nil {
		return unknown
	}
	after, ok, err := inspect(process.PID)
	if err != nil || !ok || !sameIdentity(before, after) {
		return unknown
	}
	return routeFromLaunchData(args, env, defaultHome)
}

func routeFromLaunchData(args, env []string, defaultHome string) RouteDetails {
	home := defaultHome
	for _, e := range env {
		if strings.HasPrefix(e, "CODEX_HOME=") {
			home = strings.TrimPrefix(e, "CODEX_HOME=")
			break
		}
	}
	if !filepath.IsAbs(home) || strings.ContainsAny(home, "\x00\r\n") {
		return RouteDetails{Role: "unknown"}
	}
	role := "cli"
	for _, a := range args {
		if a == "app-server" {
			role = "app-server"
			break
		}
		if a == "remote-control" {
			role = "remote-control"
			break
		}
	}
	return RouteDetails{Home: filepath.Clean(home), Role: role, Verified: true}
}
