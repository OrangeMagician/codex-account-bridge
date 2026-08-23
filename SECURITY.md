# Security Policy

## Reporting

Do not open a public issue containing tokens, account identifiers, private prompts, repository content, or SSH details. Use a private GitHub security advisory for this repository. Revoke exposed credentials through the official account controls before reporting.

## Security guarantees

`cab` never needs the contents of `auth.json`; authentication is delegated to the official Codex CLI. A report showing token content being read, copied, logged, or transmitted by `cab` is considered critical.

This project cannot guarantee the security or availability of OpenAI services, the Codex CLI, ChatGPT Remote, SSH, or the host operating system.

