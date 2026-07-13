# Hermes exact conversation continue — evidence receipt

Adapter-owned receipt for Hermes only. Does not promote readiness or enable send.

## Declared capabilities

From `agent-conversation-drivers.json` / `hermes_driver` probe:

| Field | Value |
| --- | --- |
| `exactResume` | `true` (`session/load` with requested `sessionId`) |
| `streaming` | `true` (progressive `agent.message.chunk` via turn-event sink) |
| `sendEnabled` | `false` (readiness fail-closed; `evidence_missing`) |

## Driver verification (fixture / unit)

Command (redacted):

```text
CARGO_TARGET_DIR=build/crates/lico-client-native/target \
  cargo test --manifest-path crates/lico-client-native/Cargo.toml \
  hermes_driver -- --nocapture
```

Result (2026-07-13): `8 passed; 0 failed` for `platform::hermes_driver` tests.

Proven behaviors (no live binary required):

1. Progressive streaming echo — `streaming_chunks_emit_progressive_turn_events` and `fake_child_exact_resume_keeps_native_session_id` emit ordered `agent.message.chunk` then `agent.message.completed` on the installed sink.
2. Exact continue after turn boundary — follow-up `execute(..., session_id)` uses ACP `session/load` and returns the same `nativeSessionId` (`native-hermes-exact`).
3. Interrupt boundary — cancelled / non-completed stop reasons fail closed while retaining `session_id` for a later exact resume (`interrupted_turn_keeps_native_session_for_exact_continue`).
4. Mid-run inject remains out of scope — one-shot dispatch only.

## Live verification

Attempted on 2026-07-13:

| Check | Result |
| --- | --- |
| `hermes` on PATH / `HERMES_PATH` / `HERMES_BIN` | unavailable |
| Live `agent conversation send --stream-events` | not run |
| Live exact follow-up to real `nativeSessionId` | not run |

**Verdict:** implementation + fixture proof landed; live official-lane proof blocked on missing Hermes Agent executable. Readiness stays fail-closed (`sendEnabled: 0`) until consecutive release-UI evidence exists.

## Privacy

This receipt contains no prompts, paths, account data, machine identity, or raw runtime logs.
