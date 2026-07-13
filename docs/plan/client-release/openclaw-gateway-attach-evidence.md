# OpenClaw Gateway-native attach (redacted)

Date: 2026-07-13

## Port strategy

| Port | Role |
| --- | --- |
| 18789 | Vendor OpenClaw Gateway default. **Probe/attach/reuse only** (status/install). **Never bind or steal.** |
| 24189+ | Arc-owned fallback when 18789 is unreachable. Reserved-conflict scan skips 18789, 19001, 24173, and Arc common ports. |

## Attach flow

1. Reuse healthy Arc-managed Gateway state when present.
2. HTTP-probe vendor `http://127.0.0.1:18789` (`/v1/models` or `/`). If healthy → `attachMode=vendor-default` (no owned pid; stop only detaches).
3. Else start Arc-owned `openclaw gateway … run` on uncommon port with isolated portable-data state (`--bind loopback --auth none --allow-unconfigured`).
4. Conversation send attaches ACP via `openclaw acp --url ws://127.0.0.1:<port>` (exact resume via ACP `session/load` + Gateway session key; streaming via `agent_message_chunk` → `agent.message.chunk`).

CLI: `lico-client openclaw-gateway ensure|status|stop|start|restart`

## Unit verify

`cargo test --lib openclaw_` → **11 passed** (gateway port policy, vendor remap, ACP exact resume, fake-child stream+session key).

## Live verify (this host)

| Check | Result |
| --- | --- |
| `openclaw` on PATH | absent |
| Vendor 18789 HTTP | unreachable |
| Arc 24189 HTTP | unreachable |
| Readiness `sendEnabled` | remains **0** (fail-closed; no consecutive release-UI evidence) |

## Blockers

- No local OpenClaw binary / no healthy Gateway listener → live stream + exact continue cannot be proven on this node.
- Install/start vendor Gateway (`openclaw gateway status|install|run`) or place `openclaw` on PATH, then re-run live `agent conversation send --stream-events` against the attached session id.
- Do not promote readiness until three consecutive official-lane evidence passes land.
