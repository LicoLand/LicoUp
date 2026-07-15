# Kimi Code exact-continue evidence

Date class: 2026-07-14. Redacted receipts only.

## Implementation

- Driver uses official `kimi acp` as its only conversation transport; the retired server/Wire driver and fallback were removed.
- New conversation uses `session/new`; exact continue uses `session/load` and fails closed rather than substituting a new session.
- Exact resume contract: non-empty `sessionId` continues that id; selection never falls back to newest.
- Streaming contract: ACP agent-message chunks emit `agent.message.chunk` in arrival order.
- Prompt and session identity are written only to stdin; the supervised process tree is reclaimed on every terminal path.

## Release verification (redacted)

| Check | Result | Code / note |
| --- | --- | --- |
| Local official ACP handshake | pass | protocol v1; load/resume/list and negotiated content capabilities observed, values only |
| Focused driver tests | pass | new/load, exact-id preservation, stream projection, failure closure, protocol cancel, and process cleanup |
| Consecutive release runs | unverified | no promoting release-UI receipt |
| Core checks P-01–P-10 | unverified | complete live/release sequence not run |
| Readiness `sendEnabled` | `false` | evidence reducer remains fail-closed |

## Blockers

1. **Release UI authority** — future evidence must exercise the actual Flutter composer, controller and renderer, not only the packaged sidecar.
2. **Consecutive evidence** — three complete reducer-bound runs must prove the declared core and conditional checks.
3. **Public cancel handle** — ACP supports cancel, but the public lane must not claim it until a durable active-turn handle can reach the same transport.

## Readiness impact

Kimi Code is `unverified` / `sendEnabled: false` after the implementation blocker was removed. This disables only the Kimi send claim; it does not block unrelated packaging or GitHub Release.
