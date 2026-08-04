# LicoUp Local LLM Gateway

English (normative) · [简体中文](llm-gateway.zh-CN.md)

The authority is `domain/llm_gateway.rs`, `platform/llm_gateway_transport.rs`,
and the `lico-llm-gateway` sidecar. The gateway binds only to loopback and
routes by the exact client-protocol/requested-model pair; there is no global
active provider.

## Capabilities

- Codex `/v1/responses` requests can target a Kimi-compatible OpenAI Chat
  Completions upstream, including tool calls, stream events, and bounded
  `previous_response_id` history.
- Claude Code `/v1/messages` requests can route each model independently to an
  Anthropic Messages or OpenAI Chat Completions upstream.
- Kimi, DeepSeek, and Kilo API keys are separate system-keyring items protected
  by macOS owner authentication (Touch ID, Face ID where available, or the system
  password fallback). Inventory responses contain no secret suffix or value.
- A Gateway start authenticates once in the launching `licoup-cli` (Touch ID
  or the system password fallback); the sidecar receives the credentials only
  as an in-memory handoff over an inherited file descriptor and never reads
  the Keychain itself. A standalone sidecar launch without a handoff fd still
  authenticates once at startup through the previous path. Either way the
  gateway keeps only a zeroizing in-memory lease and drops it on exit. The
  selectable 7/30/60/90/180/365-day period is an upper bound for that running
  process; it never bypasses the next startup authorization.
- Changing the selected period does not revoke a running Gateway. The current
  process keeps its existing lease; the new period applies after the next
  Gateway startup and owner authorization.
- Codex and Claude Code managed configuration points only to the loopback
  Gateway. Upstream provider API keys are never copied into agent files.

## Configuration

```json
{
  "schemaVersion": 1,
  "providers": [
    {
      "id": "kimi-chat",
      "baseUrl": "https://provider.example/v1",
      "protocol": "open_ai_chat_completions",
      "credentialProvider": "kimi",
      "credentialStyle": "bearer"
    }
  ],
  "routes": [
    {
      "clientProtocol": "open_ai_responses",
      "requestedModel": "kimi-for-codex",
      "providerId": "kimi-chat",
      "upstreamModel": "provider-model-id"
    }
  ]
}
```

The shipped default config additionally defines a Kilo Gateway provider (id
`kilo`, base URL `https://api.kilo.ai/api/gateway`, OpenAI Chat Completions
protocol, Bearer credential style) whose routes map `claude-sonnet-4-6`,
`claude-opus-4-7`, and `claude-haiku-4-5` to the `anthropic/claude-sonnet-4.6`,
`anthropic/claude-opus-4.7`, and `anthropic/claude-haiku-4.5` upstream models
across all three client protocols.

The configuration must be an absolute regular file no larger than 1 MiB. Run
`lico-llm-gateway --config <absolute-path> --check` before starting the
sidecar. It listens on `127.0.0.1:15722` by default. Non-loopback HTTP
endpoints, redirects, unknown models, and unknown fields fail closed.

## Credential custody

The desktop settings page accepts multiple Kimi, DeepSeek, and Kilo keys. The API-key
field is obscured and sent to the native CLI over private stdin. After saving,
an entry can only be deleted; reveal, copy, and edit operations do not exist.
Each delete removes the corresponding Keychain item and revokes active process
leases through a local epoch marker.

The native surface is closed to these operations:

- `llm-gateway credentials status`
- `llm-gateway credentials list`
- `llm-gateway credentials create --stdin-json true`
- `llm-gateway credentials delete <credential-id>`
- `llm-gateway credentials lease <days>`
- `llm-gateway service status`
- `llm-gateway service start [--port]`
- `llm-gateway service stop [--port]`
- `llm-gateway agent-config plan <codex|claude-code> <absolute-config-root>`

The agent configuration command produces a reviewable, secret-free plan. Codex
uses an official custom `model_providers` profile with a Responses API base URL;
Claude Code uses its official `ANTHROPIC_BASE_URL`/`apiKeyHelper` gateway fields.
Unknown agents fail closed until a precise adapter is added to the canonical
runtime registry.
