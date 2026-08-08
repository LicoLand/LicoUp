# packages/contracts/client -- DTO Schemas

This directory defines the DTO schemas owned by the LicoUp client boundary.
They cover local agent execution, conversation backup, and encrypted mobile
relay without defining a default server-ingestion path. Endpoint-protection
DTOs belong only to the
[current retiring Preview](../../../docs/STATUS.md), not to a stable Lico Arc
Profile or future compatibility contract.

## Schemas

| Schema | Description |
|---|---|
| `AgentConversationAdapter` | Executable contribution contract for an official local agent transport: identity, framing, configuration authority, operations, realtime events, routed distillation context, bounded lifecycle, privacy and exact-artifact acceptance. The starter template and the exact packaged-set canonical manifests live under `fixtures/agent-conversation-adapter/`. |
| `SnapshotArchive` | Snapshot archive descriptor for config / state restore operations. Lists bundled files, metadata, timestamps, and restore order. |
| `MobileRelayConfig` | Mobile relay configuration: relay endpoint, keep-alive interval, supported device profiles, connection credentials. |
| `OptionalCollaborationPlugin` | Disabled-by-default, non-executable GitHub package manifest for explicit Meshrix collaboration. |
| `OptionalCollaborationLocalDeployment` | Manual-only selectable local deployment feature catalog. |
| `OptionalCollaborationMcpInstall` | Manual-only MCP package catalog with direct per-file external-transfer approval. |
| `SemanticConversation` | Read-only semantic conversation model for native agent history: thread, execution, artifacts, audit, and raw evidence layers with privacy defaults. |

## Usage

Import the schema definitions as needed by each client component.
DTOs SHOULD be versioned via a `schema_version` field and SHOULD use Serde for
serialization.

## Governance

New schemas MUST be added here before being consumed by any client-adjacent
crate or service. Breaking changes to an existing schema MUST bump the
`schema_version` and be reflected in this document.
