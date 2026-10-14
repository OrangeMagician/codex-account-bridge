# Scheduled five-hour usage wake

CAB checks the local accounts and every configured SSH server at each enabled
scheduled time, independently of the selected page. It queries current login
and usage status before deciding. Accounts without an explicit 300-minute
window never receive an automatic probe.

A five-hour window still counting down is normally skipped. If its reset is
within five minutes of the scheduled time, CAB persists a pending check and
queries again when that reset passes. The pending check expires five minutes
after the expected reset; it never sends a late catch-up request hours later.
An expired, exhausted window with the known `rate_limit_reached` marker permits
one probe only if other windows and spending limits do not still block usage.
Unknown windows, query errors, and unknown limit markers do not trigger probes.

The probe is sent once through the official Codex executable. CAB then polls
usage at most three times. A successful CLI exit is recorded separately from
confirmation of a future five-hour reset time. Missing or failed verification
never causes another model request. Slot IDs and the existing 30-minute probe
cooldown prevent repeated execution.

## Persistent diagnostics

The Mac coordinating the schedule writes:

```text
~/.local/share/codex-account-bridge/usage-wake-events.jsonl
```

The bounded journal retains the newest 2,000 events with mode `0600`. Each event
identifies its target, account, scheduled slot, phase, and exact reason. Decision
and verification events include usage fetch time, window durations, percentages,
reset timestamps, and sanitized limit markers. It contains neither credentials
nor prompt/session contents or raw subprocess output. UTC ISO 8601 timestamps
and official Unix reset timestamps allow a reader to reconstruct local times.

Phases include `scheduler`, `decision`, `waiting`, `deferred`, `skipped`,
`request`, `request_completed`, `request_failed`, `verification`, `result`,
`verification_failed`, and `missed`. `request_completed` means only that the CLI
request finished. `five_hour_confirmed` requires an official countdown readback.
A failure to save the request journal prevents sending that request.

The scheduler runs inside CAB. A gap of over 90 seconds between ticks is logged
on resumption so sleep, application exit, or a stalled tick can be distinguished
from an account-level skip. Remote checks are coordinated by the Mac; their
events are recorded in the same Mac journal.
