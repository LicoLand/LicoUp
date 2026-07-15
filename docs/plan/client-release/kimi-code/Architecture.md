# Kimi Code exact-continue (ACP)

## Transport decision

| Concern | Lane | Notes |
| --- | --- | --- |
| History list / native id readback | ACP + disk history | `kimi acp` `session/list` / `session/load` plus bounded native history readback |
| Streaming echo + exact continue send | ACP v1 stdio JSON-RPC | `session/new` or exact `session/load`, followed by `session/prompt`; text comes from `session/update` chunks |
| Mid-run inject / steer | Out of scope | Not implemented |

Arc starts only `kimi acp`. Prompt and native session identity travel over stdin and never enter argv. A missing or rejected exact session load fails closed; the driver does not create a new replacement session and has no server/Wire fallback or attach configuration.

## Fail-closed readiness

`sendEnabled` stays false until consecutive release-UI evidence exists. Live quota/provider errors, rejected loads, and empty ACP finals fail closed and do not promote readiness. ACP protocol cancel exists internally, but the public product capability remains false until a durable active-turn handle can route a later cancel request to the same supervised transport.
