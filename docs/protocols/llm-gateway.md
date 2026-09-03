# LicoUp Local LLM Gateway

English (normative) · [简体中文](llm-gateway.zh-CN.md)

The LLM Gateway is the **lower layer** of the Gateway Runtime. Authority for
this layer is `domain/llm_gateway.rs`, `platform/llm_gateway_transport.rs`, and
the unified `lico-gateway` process (`platform/gateway_runtime`). The layer
binds only to loopback and routes by the exact client-protocol/requested-model
pair; there is no global active provider. Messaging channels are documented in
[`gateway-runtime.md`](gateway-runtime.md).

## Capabilities

- Codex `/v1/responses` requests can target a Kimi-compatible OpenAI Chat
  Completions upstream, including tool calls, stream events, and bounded
  `previous_response_id` history.
- Claude Code `/v1/messages` requests can route each model independently to an
  Anthropic Messages or OpenAI Chat Completions upstream.
- Kimi, DeepSeek, and Kilo API keys are separate system-keyring items protected
  by macOS owner authentication (Touch ID, Face ID where available, or the system
  password fallback). Inventory responses contain no secret suffix or value.
- Owner authorization (Touch ID or the system password fallback) unlocks
  credentials in the long-lived `licoup-cli` process. A cold Gateway start
  hands the unlocked session to the sidecar over an inherited file descriptor;
  the sidecar never reads the Keychain itself. While a managed Gateway is
  already running, authorize and clear hot-apply the updated lease over a
  private Unix control socket in the Gateway state directory (mode 0600, same
  uid) without restarting the process. A standalone sidecar launch without a
  handoff fd starts disconnected until a hot apply or a later start with
  handoff. The gateway keeps only a zeroizing in-memory lease and drops it on
  exit. The selectable 7/30/60/90/180/365-day period is an upper bound for that
  running process; it never bypasses the next owner authorization.
- Changing the selected period does not revoke a running Gateway. The current
  process keeps its existing lease; the new period applies on the next owner
  authorization that rebuilds the handoff (hot apply) or on the next cold start.
- Codex and Claude Code managed configuration points only to the loopback
  Gateway. Upstream provider API keys are never copied into agent files.
- Authenticated `GET /v1/models` and `GET /models` requests query each provider
  represented in the current in-memory credential lease and return its live
  `/models` response. No authorized provider credential means an empty list;
  an invalid authorized credential returns the upstream failure instead of a
  product-owned fallback catalog.

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

The shipped configuration defines only the fixed Kimi, DeepSeek, and Kilo
provider boundaries. It contains no product-owned model inventory. A model
request uses `{provider}:{upstream-model-id}` (for example
`kimi:kimi-k3`, `deepseek:deepseek-v4-flash`, or
`kilo:anthropic/claude-sonnet-4.5`); the Gateway removes only the first provider
prefix before forwarding the request. Model-list responses preserve each
upstream model object and expose the namespaced id, plus `upstream_id` and
`gateway_provider`, so combined provider catalogs remain unambiguous.
If one authorized provider is unavailable while another succeeds, the healthy
models are returned with `partial: true` and a redacted
`failed_provider_count`; model discovery has one 45-second aggregate deadline.

OpenCode and Pi require explicit custom-provider model entries. Their
agent-config plan/apply commands therefore snapshot the live list from a
running Gateway. When the Gateway is stopped, the snapshot is empty; when it
is running, an upstream catalog or credential failure fails the plan rather
than substituting fixed model names. Codex and Claude Code continue to use the
Gateway endpoint directly without an embedded model list.
The one-click OpenCode/Pi helpers refuse to apply an empty snapshot.

The configuration must be an absolute regular file no larger than 1 MiB. Run
`lico-llm-gateway --config <absolute-path> --check` before starting the
sidecar. It listens on `127.0.0.1:15722` by default. Non-loopback HTTP
endpoints, redirects, unknown providers, unnamespaced dynamic models, and
unknown fields fail closed.

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
- `llm-gateway agent-config plan <codex|claude-code|opencode|pi> <absolute-config-root>`
- `llm-gateway agent-config apply <codex|claude-code|opencode|pi> <absolute-config-root> --confirmation <digest> --confirmed [--stdin-json true]`

The agent configuration command produces a reviewable, secret-free plan. Codex
uses an official custom `model_providers` profile with a Responses API base URL;
Claude Code uses its official `ANTHROPIC_BASE_URL`/`apiKeyHelper` gateway fields.
OpenCode writes a sidecar `opencode.licoup-gateway.json` (OpenAI-compatible
Chat Completions provider) and never rewrites `opencode.json` / `opencode.jsonc`;
load the sidecar with `OPENCODE_CONFIG` so OpenCode merges it with the existing
global config. Pi writes a sidecar `models.licoup-gateway.json` (OpenAI
Completions provider) and never rewrites `models.json` wholesale; the helper
merges only `providers.licoup-gateway` into `~/.pi/agent/models.json`. Unknown
agents fail closed until a precise adapter is added to the canonical runtime
registry. OpenCode and Pi apply receive the plan's exact model snapshot through
private stdin, so upstream catalog drift after preview cannot change confirmed
content.

Developer one-click helpers (same sidecar semantics):

```bash
npm run client:opencode:add-gateway
npm run client:pi:add-gateway
```
