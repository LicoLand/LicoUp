# Provider packages (local verification)

Updated: 2026-09-25

Synthetic provider material for the v7.1 model-provider runtime. Everything here
is generated locally: no network, no account, no key material, and the endpoints
are loopback addresses that nothing listens on.

| Path | What it is |
|:---|:---|
| `compatible-local/provider.json` | A compatible-API configuration. It needs no provider code; the host transport for `openai-chat-compatible` serves it. |
| `compatible-local/stream-fixture.jsonl` | The synthetic stream the compatible transport replays: text chunks, a partial usage report and a terminal frame with an unknown cost amount. |
| `synthetic-custom/` | A package for the non-compatible dialect `synthetic.example/native`: `provider.py` is a real extension process speaking the `model-provider` JSON-RPC profile, with its own stream adapter and a device-code authentication flow. |

`provider.py` is exercised by the Rust integration tests under
`tests/integration/v71_model_providers/`; it is not installed into any client.
