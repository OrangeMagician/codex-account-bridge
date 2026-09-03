# CodexAccountBridge

<p align="center">
  <strong>English</strong> · <a href="README.zh-CN.md">简体中文</a>
</p>

<p align="center">
  <img src="macos/CABDesktop/Resources/AppIcon.png" width="160" alt="CodexAccountBridge app icon">
</p>

CodexAccountBridge (`cab`) is an open-source Codex account manager for macOS and Linux. It provides a command-line tool and a native SwiftUI app for managing multiple official Codex or ChatGPT logins across local machines, SSH servers, remote projects, and supported agent services.

CAB keeps every login in an independent `CODEX_HOME` and delegates authentication and model traffic to the official Codex executable. It does not implement OAuth, proxy model requests, inspect token contents, or silently switch accounts after quota, authentication, or runtime errors.

## What it does

- Manage multiple official Codex logins without merging their credentials.
- Select an account explicitly for a CLI launch, the Codex desktop app, or a remote Codex app-server.
- View official Codex usage limits and reset windows for each account.
- Optionally receive local macOS notifications when a reported usage window reaches its reset time.
- Optionally start a recovered or not-yet-started usage countdown with one minimal official Codex request, with paused-refresh periods and up to three explicit daily start times.
- Manage accounts on multiple SSH servers from the native macOS app.
- Preserve or isolate project and session history during deliberate account changes.
- Opt in to cross-account session sharing with explicit disclosure and process checks.
- Bind supported Hermes and OpenClaw systemd user services to a chosen Codex account.
- Configure a visible launch rotation order without reacting to quota or errors.

## Security model

CodexAccountBridge is intentionally conservative:

- Each account receives a separate `CODEX_HOME` and signs in through official `codex login` flows.
- CAB never reads, parses, exports, or copies the contents of `auth.json`.
- The official `codex` executable is invoked directly, without a shell or argument rewriting.
- Codex approval, sandbox, and project-trust defaults remain unchanged.
- Normal usage reads are display-only. The optional usage-period wake is an explicit, opt-in minimal request and never rotates accounts because of rate limits, login failures, or runtime errors.
- Session sharing excludes credentials, `config.toml`, and SQLite/WAL state, and requires explicit acknowledgement.
- Configuration updates are locked, atomic, permission-restricted, and recoverable from backups.

See the [threat model](docs/THREAT_MODEL.md), [privacy notes](docs/PRIVACY.md), and [upstream safety audit](docs/UPSTREAM_AUDIT.md) for the detailed boundaries.

## Installation

Requirements:

- The official Codex CLI installed and available on `PATH`.
- Go 1.26.7 or newer for building the current source tree.
- macOS 13 or newer for the native desktop app.

```bash
git clone https://github.com/OrangeMagician/codex-account-bridge.git
cd codex-account-bridge
make check
make security-check
make build
install -m 0755 bin/cab ~/.local/bin/cab
```

Make sure `~/.local/bin` is on `PATH`, then initialize CAB:

```bash
cab init
cab version
```

## Manage Codex accounts

Create independent account homes and complete the official login flow:

```bash
cab account add personal
cab account add work

# Browser login on macOS or Linux desktops
cab login personal

# Device login on headless Linux servers
cab login --device-auth work

cab account list
```

Choose an account explicitly and launch the official Codex CLI:

```bash
cab use personal
cab run

cab run --account work -- exec "explain this repository"
```

Arguments after `cab run` are passed through to the official Codex executable. Removing a CAB registration does not delete the account directory, login, or sessions.

If the default `~/.codex` directory is already signed in, register it without copying credentials:

```bash
cab account import-current current
```

CAB verifies the login through official `codex login status` and records the existing directory. It does not open or copy the credential file.

## Inspect official usage limits

CAB starts the official `codex app-server` under each selected `CODEX_HOME` and requests the account's available usage information:

```bash
cab usage
cab usage --account personal
cab usage --json
```

Depending on the official response, the report can include the ChatGPT plan type, primary and secondary Codex usage windows, reset times, credits, spend controls, and available rate-limit resets. Account identity, email addresses, token contents, and reset credential identifiers are not exposed.

When an account reports an available rate-limit reset, the macOS app shows a Reset usage button. A bright warning sheet requires a second confirmation and calls the official Codex reset-credit method with an idempotency key. It warns when usable five-hour or weekly capacity would be replaced, then refreshes both windows after the operation. CAB lets the backend select the credit and never reads or persists its opaque identifier.

The macOS app includes an optional usage-reset notification switch in System Settings. It is off by default and requests system notification permission only when enabled. CAB replaces its scheduled notifications whenever usage data is refreshed and removes them when the switch is turned off. A notification indicates that the reported reset time has arrived; refresh CAB to confirm the latest server-side quota.

Automatic refresh is evaluated per account and continues at the configured interval even when an account reports zero remaining usage. Manual refresh still queries every account. The System Settings usage-period wake switch is off by default. When enabled, CAB checks usage after a recovered period or at up to three explicit daily start times, then sends one deliberately tiny `gpt-5.6-luna` request only when the five-hour or weekly window has no active countdown. Up to three paused-refresh periods suppress ordinary automatic reads and recovery-triggered probes; explicit start times take priority. CAB verifies the returned reset window after a wake request and does not retry a failed probe automatically.

The low-level probe is also available for a deliberate manual check:

```bash
cab usage probe --account personal
```

It invokes the official Codex executable with an ephemeral, read-only temporary workspace and never persists a session or exposes the response.

Usage information never triggers an automatic account change.

## Native macOS app

CodexAccountBridge includes a native SwiftUI interface for local and remote account management:

```bash
make macos-app VERSION=0.6.16 BUILD_NUMBER=27
open "dist/CodexAccountBridge.app"
```

The app can:

- Switch between this Mac and saved SSH servers.
- Register, sign in, reauthenticate, and inspect independent accounts.
- Display quota summaries and detailed official usage periods.
- Configure optional usage-period wake checks, daily start times, and paused-refresh periods from System Settings.
- Launch the Codex desktop app with a selected local account.
- Select the account used by new remote Codex connections.
- Preserve approved projects, complete chat content and catalog state, goals, memories, personal skills, attachments, prompt history, and unsent drafts during deliberate desktop account changes.
- Manage session-sharing policy, launch rotation, and supported agent bindings.

Saved server labels and SSH host strings remain in local macOS `UserDefaults`. SSH identity files and private-key contents are not imported into CAB.

## Remote Codex over SSH

Install CAB on the remote host, select the account used by new remote Codex app-server processes, and install the shim:

```bash
cab remote use work
cab shim install --dir ~/.local/bin --force
command -v codex
codex --version
```

The shim routes new `codex app-server` launches through the explicitly selected remote account. An already running remote Codex process keeps the account it started with; close that remote task and reconnect after changing accounts.

For the phone-to-desktop-to-Ubuntu workflow and SSH details, see [Remote setup](docs/REMOTE.md).

## Session isolation and sharing

Sessions are isolated by default. To let one account resume another account's history, stop the affected Codex processes and acknowledge the cross-account disclosure:

```bash
cab sessions enable \
  --acknowledge-cross-account-context \
  --confirm-codex-stopped

cab run --account work -- resume --last
```

Return to independent session copies with:

```bash
cab sessions disable --confirm-codex-stopped
```

CAB stops on conflicting session files instead of overwriting either side. Timestamped backups are retained for recovery.

## Optional launch rotation

Rotation is disabled by default. When enabled, it only selects the next account before a new `cab run` without an explicit `--account`:

```bash
cab rotation configure --accounts personal,work
cab rotation enable
cab rotation status

cab run
cab run

cab rotation disable
```

Explicit account selection always wins. Rotation does not inspect usage and does not retry failed work with a different login.

## Supported agent bindings

On Linux servers, CAB can discover supported Hermes gateway/bridge and OpenClaw gateway systemd user services. Bindings are explicit and independent from the remote Codex selection:

```bash
cab agent list
cab agent bind --service hermes-gateway-coder.service --account work --confirm-restart-agent
cab agent bind-all --account work --confirm-restart-agent
cab agent unbind --service hermes-gateway-coder.service --confirm-restart-agent
```

CAB writes a managed `CODEX_HOME` systemd drop-in. It does not copy credentials. Active services are restarted only after explicit confirmation; inactive services are not started automatically.

## Diagnostics

```bash
cab doctor

# Only when doctor reports an interrupted session migration
cab doctor --repair
```

Diagnostics inspect executable availability, directories, symlinks, transaction state, and permissions. They do not inspect token contents or conversation text.

## Configuration paths

- Configuration: `${XDG_CONFIG_HOME:-~/.config}/codex-account-bridge/config.json`
- Account data: `${XDG_DATA_HOME:-~/.local/share}/codex-account-bridge/`
- Portable/test overrides: `CAB_CONFIG_HOME` and `CAB_DATA_HOME`
- Official executable override: `CAB_REAL_CODEX=/absolute/path/to/codex`

## Non-goals

- Automatic switching based on quota, rate limits, authentication failures, or runtime errors.
- A third-party OpenAI-compatible API proxy.
- Custom OAuth, token import/export, or a browser-based token dashboard.
- Real-time replication of Codex internal databases between machines.
- Changing Codex approval, sandbox, or project-trust behavior.

## Development

```bash
make check
make security-check
make release VERSION=0.6.16
make macos-app VERSION=0.6.16 BUILD_NUMBER=27
```

This repository does not use GitHub Actions. Release binaries and SHA-256 files are built and verified locally by the maintainer.

## License

Apache License 2.0. Codex and ChatGPT are trademarks of their respective owners. This project is not affiliated with or endorsed by OpenAI.
