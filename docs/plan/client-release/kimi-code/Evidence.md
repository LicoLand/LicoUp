# Kimi Code exact-continue evidence

Date class: 2026-07-13. Redacted receipts only.

## Implementation

- Driver prefers persistent `kimi server run` Wire attach for send/streaming.
- ACP retained for capability probe, list/load semantics, and send fallback when server session/stream routes are incompatible or unavailable.
- Arc never binds `58627` or `5494` (vendor server / legacy web). OpenCode serve reserved ports include both.
- Exact resume contract: non-empty `sessionId` continues that id; selection never falls back to newest.
- Streaming contract: Wire `ContentPart` text emits `agent.message.chunk` when the server stream is used.

## Live verify (redacted)

| Check | Result | Code / note |
| --- | --- | --- |
| Unit tests (`kimi_code*`) | pass | 13 focused tests |
| Vendor binary present | pass | local kimi-code CLI |
| ACP `loadSession` | pass | advertised true |
| Prefer-path server ensure | pass | listener owner class `kimi` on `58627`; Arc/`lico*` not owner |
| Prefer-path session create | blocked → ACP fallback | `kimi_code_server_session_id_missing` then ACP |
| ACP turn under quota | fail-closed | `kimi_code_acp_final_message_missing`; `nativeSessionId` length class 44 |
| Streaming chunks | absent under quota | only `dispatch.turn.started` then `done` |
| Exact continue canaries | blocked | provider usage limit |
| Readiness `sendEnabled` | unchanged `false` | evidence_missing |

## Blockers

1. **Provider quota** — `-p` and ACP/Wire turns yield empty finals while the billing cycle is exhausted.
2. **Server session create schema** — health attach works; create response id field for this CLI class still unresolved, so send falls back to ACP until OpenAPI-backed mapping lands.
3. **Release-UI consecutive passes** — still required before readiness promotion.

## Readiness impact

None. Kimi Code remains `unverified` / `sendEnabled: false`.
