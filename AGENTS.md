# Project rules

- Never add GitHub Actions or a `.github/workflows` directory.
- Never read, copy, print, upload, parse, or share the contents of `auth.json`.
- Account selection must be explicit unless the user has deliberately enabled a visible launch-rotation order. Never rotate in response to quota, rate-limit, authentication, or runtime errors.
- Invoke the official `codex` executable directly without a shell.
- Preserve Codex approval, sandbox, and project-trust defaults.
- Treat cross-account session sharing as opt-in data disclosure.
- Keep runtime dependencies at zero unless a reviewed dependency is essential.
- Run `go test ./...`, `go test -race ./...`, `go vet ./...`, and local release builds before delivery.
