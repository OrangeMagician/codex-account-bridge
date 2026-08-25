.PHONY: check build macos-app release clean

VERSION ?= dev
LDFLAGS := -s -w -X main.version=$(VERSION)

check:
	go test ./...
	go test -race ./...
	go vet ./...

build:
	mkdir -p bin
	go build -trimpath -ldflags "$(LDFLAGS)" -o bin/cab ./cmd/cab

macos-app:
	./scripts/build-macos-app.sh

release:
	./scripts/build-release.sh "$(VERSION)"

clean:
	rm -rf bin dist
