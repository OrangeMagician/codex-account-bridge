# Project rules

- Never add GitHub Actions or a `.github/workflows` directory.
- Never read, copy, print, upload, parse, or share the contents of `auth.json`.
- All account selection must be explicit. Do not implement automatic quota rotation.
- Invoke the official `codex` executable directly without a shell.
- Preserve Codex approval, sandbox, and project-trust defaults.
- Treat cross-account session sharing as opt-in data disclosure.
- Keep runtime dependencies at zero unless a reviewed dependency is essential.
- Run `go test ./...`, `go test -race ./...`, `go vet ./...`, and local release builds before delivery.

