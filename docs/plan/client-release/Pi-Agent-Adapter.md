# Pi Agent Adapter Plan

## Discovery

- **Product**: Pi Coding Agent — minimal open-source terminal coding harness ([pi.dev](https://pi.dev), [`@earendil-works/pi-coding-agent`](https://github.com/earendil-works/pi)).
- **Local binary**: `pi` (npm global package `@earendil-works/pi-coding-agent`).
- **Official integration lane**: `pi --mode rpc` — LF-delimited JSONL over stdin/stdout ([docs/rpc.md](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/rpc.md)). Prefer this over inventing ACP.
- **Session continue**: CLI `--session` / `-c` / `-r` exist, but exact resume for Arc uses RPC `switch_session` with a resolved session file path so prompts and session identity stay off argv.
- **History**: JSONL under `~/.pi/agent/sessions/--<cwd>--/<timestamp>_<uuid>.jsonl` (header `type: session`, messages nested under `message`).

## Contract

| Concern | Decision |
| --- | --- |
| Packaged id | `pi` |
| Driver id | `pi-rpc` |
| Runtime protocol | `pi-rpc-stdio-jsonl` |
| Launch argv | Fixed `--mode rpc` (+ `--offline`); never prompt/session id |
| New send | RPC `get_state` binds the real session id before `prompt`; realtime message updates then carry that id |
| Exact resume | Resolve one exact JSONL header id under the selected session store → RPC `switch_session` → verify `get_state` identity → `prompt` |
| Readiness | Enter as `unverified`, `sendEnabled: false` until CL-06 live evidence |
| Extension UI | Fail closed with `pi_user_interaction_required` |

## Delivery checklist

1. [x] Native driver + fail-closed tests under `crates/lico-client-native`
2. [x] Inventory / readiness resources + `PACKAGED_RUNTIME_ADAPTER_IDS`
3. [x] Packaging `targetAdapters`, targets/proxy/usage projections
4. [x] Native history roots + Pi JSONL parser
5. [x] Icons + render adapter
6. [x] Docs projections that list packaged adapters
7. [x] Disposable acceptance session root, exact-id cleanup, and Pi-specific strict-LF RPC harness

## Blockers

- `sendEnabled` remains false (`unverified`) until CL-06 live/release evidence exists.
- Extension UI dialogs fail closed (`pi_user_interaction_required`).
- Exact resume requires a resolvable session file under the Pi session store; unresolved ids fail with `pi_session_not_found` rather than placing identity on argv.
- Public cancel remains unsupported because ordinary sends do not share one durable Pi RPC process; the official RPC `abort` command alone is not a product-level cross-command cancel handle.
