# ADR-0007: User shell environment for Agent launches

Updated: 2026-09-25

Status: implemented · Current authority:
`crates/licoup-foundation/src/platform/user_shell_environment.rs`

## Decision

LicoUp captures one bounded snapshot of the user's login-shell environment per
native process. Registered Agent probes and launches apply that snapshot before
their own explicit functional environment values. Executable discovery searches
the snapshot's `PATH` before the supplementary Agent scan manifest.

Capturing the environment does not launch an Agent, send a prompt, enumerate
every directory in `PATH`, or upload path and command data. If the login-shell
capture cannot produce a valid bounded snapshot, the implementation uses its
documented process-environment fallback.

## Trade-off

One shared snapshot keeps probes and launches in the same command-line
environment without starting one shell per Agent. It preserves the current
environment boundary while keeping each driver responsible for its own command,
arguments, and functional overrides.

Source and focused tests own the exact framing, bounds, fallback, and
environment precedence.
