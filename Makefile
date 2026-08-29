.PHONY: check check-go security-check build macos-app release local-release clean

VERSION ?= dev
BUILD_NUMBER ?= 0
GO ?= go

check-go:
	./scripts/check-go-version.sh "$(GO)"

check: check-go
	$(GO) test ./...
	$(GO) test -race ./...
	$(GO) vet ./...
	swift test --package-path macos/CABDesktop

security-check: check-go
	$(GO) run golang.org/x/vuln/cmd/govulncheck@v1.1.4 ./...

build: check-go
	GO="$(GO)" ./scripts/build-cli.sh "$(VERSION)"

macos-app:
	./scripts/build-macos-app.sh "$(if $(filter dev,$(VERSION)),0.0.0,$(VERSION))" "$(BUILD_NUMBER)"

release: check security-check
	GO="$(GO)" ./scripts/build-release.sh "$(VERSION)"

local-release: release macos-app

clean:
	rm -rf bin dist
