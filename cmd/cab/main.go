package main

import (
	"fmt"
	"os"
	"path/filepath"

	"github.com/OrangeMagician/codex-account-bridge/internal/app"
)

var version = "dev"

func main() {
	code, err := app.Run(os.Args, version)
	if err != nil {
		name := filepath.Base(os.Args[0])
		fmt.Fprintf(os.Stderr, "%s: %v\n", name, err)
	}
	os.Exit(code)
}
