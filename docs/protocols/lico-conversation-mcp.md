# LicoUp Conversation MCP

English (normative) · [简体中文](lico-conversation-mcp.zh-CN.md)

Authority: `crates/licoup-native/src/bin/lico-conversation-mcp.rs` and
`crates/licoup-native/src/domain/client_conversation/`. Update this projection
when those implementations or their verification change.

`lico-conversation-mcp` is a local stdio MCP server packaged beside the desktop
client. It reads and writes only LicoUp's canonical Conversation store under
private client state. It never rewrites a third-party Agent's native history or
exposes private native continuation locations.

Server name: `lico-up-conversations`.

## Tools

| Tool | Purpose |
| --- | --- |
| `lico_conversation_list` | List up to 100 canonical Conversation summaries; archived Conversations are excluded unless requested |
| `lico_conversation_get` | Read one Conversation by stable `conversationId` |
| `lico_conversation_search` | Search structured Event text through the bounded full-text index |
| `lico_conversation_export` | Export selected or bounded-all canonical Conversations to a JSON bundle path |
| `lico_conversation_import` | Import a current canonical bundle without overwriting an identity collision |

All input objects are closed and bounded. Search is keyword/full-text search,
not caller-provided regular-expression execution. Import and export operate on
the canonical Conversation schema; deprecated projection-store flags and
native session identifiers are not part of the contract.

## Canonical model

One-to-one and group chat are the same Conversation model. Human and Agent
Principals participate as peer Memberships. Access, membership lifecycle,
runtime availability, collaboration Role, and native execution binding are
separate facts.

Visible history is an ordered structured Event stream. Roles contain ordered
pools of eligible Agent Memberships. An Adaptive Flywheel contains ordered Role
stages and resolves them as `single`, `round-robin`, `all`, or
`bounded-parallel`. A run freezes role and candidate snapshots before work is
claimed, so later edits cannot change an in-flight run.

The generated Conversation bridge is the application contract for mutations,
event paging, role/flywheel authoring, run start/read/continue/cancel, atomic
turn claim/transition, and import/export. MCP intentionally exposes only the
bounded management subset above.

## Privacy and migration

Native runtime session identifiers, continuation locations, and working
directories are private store fields and are omitted from public Conversation,
MCP, export, and generated bridge values. The one-time native migration imports
supported LicoUp-owned legacy state, records its migration version, and removes
retired projection, singleton-group, TOML-flywheel, and file-handoff stores only
after validation. Unsupported non-empty legacy transcripts fail closed rather
than being silently discarded.
