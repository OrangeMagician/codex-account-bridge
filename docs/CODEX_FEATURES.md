# Codex catalogs, tasks and worktrees

CAB uses official Codex app-server over stdio in one explicitly selected
`CODEX_HOME`. It does not implement authentication or perform an inference
request to verify model access. Models returned by `model/list` are the client's
catalog; final access depends on the account, workspace policy and service.

## Models and launch presets

```sh
cab models --account work --json
cab run --account work --directory /absolute/project \
  --model gpt-6.1-sol --effort high --speed fast
```

The native app's **Models and speed** page reads the selected account's catalog.
Project launch profiles can save a model, reasoning effort and speed. Old
profiles remain valid and use official defaults. CAB checks the latest catalog
again before launching an explicit preset, including on an SSH target. A failed
check does not select another account, change the preset or launch with a fallback.
The model catalog is not an entitlement check and may depend on the CLI version.

Only returned reasoning levels and speed tiers are selectable. The catalog
recommendation may differ from a user's configured default, so changing
reasoning or speed requires an explicit model. Leaving every field unset preserves
the user's official configuration.
Codex's request tier `priority` is presented as Fast; the CLI's
`service_tier="fast"` maps to it.
The Standard option appears only if explicitly advertised; leaving the speed
unset preserves the official configured default, which may already be Fast.
Fast and Ultrafast show the current published subscription and Credits usage
multipliers. Those notices are separate from the standard API-equivalent Token
estimate, which does not include speed premiums.

Known retirement notices are shown without silently replacing models. GPT-5.5
retires from Codex with ChatGPT sign-in on October 14, 2026. Historical Token
records keep their valuation. Managed requirements and official model access
still apply. CAB does not write `config.toml`, approval, sandbox or project trust.

## Process routing

`cab doctor --json` includes `routes` when the process inspection succeeds.
For each same-user Codex process CAB verifies its UID, start time and executable
before and after inspecting the launch environment. Only `CODEX_HOME` and a role
are projected into the report. Other arguments and environment values are not
printed, stored or forwarded. Permission failures and process races yield
`verified: false`, not a guessed account.

The report separates the next connection account from existing processes.
Changing an account does not restart a background server or interrupt its tasks.
A separate stdio query process cannot establish live status in another server.

## Stored tasks

```sh
cab tasks list --account work --search title --directory /absolute/project --json
cab tasks list --account work --cursor OPAQUE_CURSOR --json
cab tasks list --account work --archived --json
cab tasks pin --account work --id THREAD_ID --value true --json
cab run --account work --resume THREAD_ID
```

The **Recent tasks** page supports title and exact project-path filters,
archived/pinned history and pagination. It projects title, ID, cwd, timestamp and
pin state; it does not return prompt previews, transcript items or live status.
Shared/imported history is not proof of original account ownership. Restoring a
task is an explicit action through official Codex using the selected account.
Archived tasks are inspectable, with the resume action disabled.

Pin updates verify the field returned by the official server. Older servers
that ignore `isPinned` produce an unsupported-feature error. Older CAB targets
are checked through `capabilities` before issuing new commands.

## CAB worktrees

```sh
cab worktrees create --account work --directory /absolute/repository --ref main --json
cab worktrees list --account work --json
cab worktrees remove --account work --id REGISTERED_ID \
  --confirm --confirm-codex-stopped --json
```

These are CAB-owned Git worktrees, separate from the official desktop's internal
registry. They start at a verified commit in detached HEAD mode, with private
directories under `$CAB_DATA_HOME/worktrees`. Creating them does not copy
uncommitted changes or grant Codex project trust. Git hooks are disabled for
CAB's worktree operations; inherited Git environment overrides are excluded.
Tracked files named `auth.json` are rejected by filename before checkout, without
reading their contents. Registration reads refuse symlinks at open time.

Removal requires an exclusive CAB maintenance lease and no running Codex
processes. It refuses tracked or untracked local changes, missing directories,
symlinks, unregistered IDs and another account's registrations. Before removal,
the current commit is retained under `refs/cab/worktree-archives/ID` in the source
repository. Recover committed work with `git show refs/cab/worktree-archives/ID`
or create a new checkout from that ref. CAB never force-removes a worktree.

## Plugin maturity

The model page links to official API documentation and states that plugin list,
install and uninstall endpoints are under development. CAB does not call these
endpoints in production, nor copy plugin authorization between accounts.

## Official references

- [App-server](https://learn.chatgpt.com/docs/app-server)
- [Configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference)
- [Speed and usage multipliers](https://learn.chatgpt.com/docs/agent-configuration/speed)
- [Model availability and retirements](https://learn.chatgpt.com/docs/models)
- [GPT-6.1 Sol pricing](https://developers.openai.com/api/docs/models/gpt-6.1-sol)
