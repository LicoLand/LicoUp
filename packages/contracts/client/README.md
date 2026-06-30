# packages/contracts/client -- DTO Schemas

This directory defines the required DTO (Data Transfer Object) schemas for the
LicoLite client contract boundary. These schemas govern the wire format between
the client shell and backend services / runtime components.

## Schemas

| Schema | Description |
|---|---|
| `TargetAdapterConfig` | Configuration DTO for target-specific adapters (Antigravity, Claude Code, Codex, Cursor, GitHub Copilot, Hermes Agent, Kilo Code, OpenClaw, OpenCode). Defines per-target file paths, CLI invocation patterns, and native config read/write rules. |
| `McpPluginPlan` | MCP plugin registration plan: plugin ID, source URI, capability declarations, trust level, and lifecycle hooks. |
| `SnapshotArchive` | Snapshot archive descriptor for config / state restore operations. Lists bundled files, metadata, timestamps, and restore order. |
| `ThinForwardingRule` | Thin forwarding rule: model alias, upstream endpoint, auth token reference, request/response transformation hints. |
| `MobileRelayConfig` | Mobile relay configuration: relay endpoint, keep-alive interval, supported device profiles, connection credentials. |
| `LocalRuntimeStatus` | Local runtime status payload: process health, port binding, uptime, claim token validity, active features. |
| `ProcessIdentityClaim` | Process identity claim token: public key fingerprint, capability set, expiry, signature. |

## Usage

Import the schema definitions as needed by each consumer crate or service.
DTOs SHOULD be versioned via a `schema_version` field and SHOULD use Serde for
serialization.

## Governance

New schemas MUST be added here before being consumed by any client-adjacent
crate or service. Breaking changes to an existing schema MUST bump the
`schema_version` and be reflected in this document.
