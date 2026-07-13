# Copilot exact-continue research (redacted)

Date: 2026-07-13. Host facts only; no account, path, token, session body, or raw model text.

## Official native surfaces

| Surface | Exact `nativeSessionId` | Prompt privacy | Streaming | Role for Arc |
| --- | --- | --- | --- | --- |
| CLI `--continue` | No — newest/most-recent only | Interactive / `-p` argv | Interactive TTY; `-p` batch | Reject for Arc exact continue |
| CLI `--resume[=id]` | Yes — UUID, name, or 7+ hex prefix; can also mint a UUID | `-p` puts prompt on argv; resume id on argv | Same as `-p` batch | Secondary only; argv-bound like Claude leave |
| SDK / session-state (`--server\|--headless --stdio`, Content-Length JSON-RPC) | Yes via `session.list` / `session.delete` in harness | RPC body, not argv | Cleanup/list proven in harness; turn API not yet Arc-owned | Preferred native identity + cleanup authority |
| ACP `--acp --stdio` | Yes — `loadSession` advertised; `session/load` keeps id off argv | Prompt on stdio JSON-RPC | `agent_message_chunk` watchable | Keep as thin turn bridge if SDK turn lane missing; do not over-invest |

## Live facts (minimum)

- Copilot CLI present (`1.0.46` class). Auth method id `copilot-login` available on ACP initialize.
- ACP: `authenticate` → `session/new` → streamed chunks → process boundary → `session/load` same id → second turn streamed. Chunk counts were progressive (tens of chunks). Canary string match was unreliable (model verbosity); identity match held.
- Current Arc ACP driver does **not** send `authenticate`; without it `session/new` fails closed as authentication-required (`-32000`).
- CLI `-p` new-session on this host exited non-zero with a **model**-class stderr marker; not used as green send evidence.
- SDK Content-Length `connect` variants timed out in a short probe; harness still owns `session.list` / `session.delete` for cleanupKind `copilot-sdk`.
- Session-state layout (names only): per-id directory with `session.db`, `events.jsonl`, `checkpoints/`, `workspace.yaml`; plus catalog `session-store.db`.

## Native-first posture (owner direction)

1. Prefer SDK session-state for list / delete / identity continuity; never Arc `--continue` (newest).
2. Do not promote argv `--resume=<id>` + `-p` as the secure product lane (session id and prompt on argv); same class of concern as Claude Code argv resume unless an owner decision carves an exception.
3. Use ACP only as a thin turn/stream bridge when needed (`authenticate` + `session/load|new` + chunk emit); stop expanding ACP-specific protocol surface.
4. Keep `sendEnabled: false` until a native-first lane proves: watchable stream during a turn, then follow-up on the **exact** id after finish/interrupt, with consecutive release-UI evidence.

## Readiness impact

Unchanged fail-closed: Copilot remains `unverified` / `evidence_missing`, `sendEnabled: 0`.
