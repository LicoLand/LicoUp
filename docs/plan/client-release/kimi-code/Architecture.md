# Kimi Code exact-continue (server Wire attach)

## Transport decision

| Concern | Lane | Notes |
| --- | --- | --- |
| History list / native id readback | ACP + disk history | `kimi acp` `session/list` / `session/load` remain OK |
| Streaming echo + exact continue send | Persistent `kimi server run` Wire | Default vendor port `58627`; Wire `prompt` over session WebSocket |
| Mid-run inject / steer | Out of scope | Not implemented |

Arc never binds `58627` or `5494`. Those ports are reserved against OpenCode serve selection and against Kimi attach-to-legacy-web. When a daemon is missing, Arc may spawn `kimi server run --keep-alive --port 58627` so **Kimi** owns the listen socket.

## Fail-closed readiness

`sendEnabled` stays false until consecutive release-UI evidence exists. Live quota/provider errors and empty Wire finals fail closed and do not promote readiness.
