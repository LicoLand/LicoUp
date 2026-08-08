# LicoUp Conversation MCP

English (normative) · [简体中文](lico-conversation-mcp.zh-CN.md)

Authority: `crates/licoup-native/src/bin/lico-conversation-mcp.rs` and
`domain/owned_conversations/`. Update this projection when those
implementations or their verification change.

`lico-conversation-mcp` is a **local stdio MCP server** packaged beside the
desktop client. It queries **LicoUp-owned** conversations only: the parent
projection store
(`{portable}/client-state/agent-conversation-projections.json`) and the default
Lico group room. It does **not** rewrite third-party native agent history.

Server name: `lico-up-conversations`.

## Tools

| Tool | Purpose |
| --- | --- |
| `lico_conversation_list` | Bounded summary list |
| `lico_conversation_get` | Exact lookup by local `id` or `nativeSessionId` |
| `lico_conversation_search` | `matchMode=keyword` (default) or `regex` over title, ids, paths, and message text |
| `lico_conversation_export` | Write a JSON bundle to an absolute path (`conversationIds` optional) |
| `lico_conversation_import` | Merge a prior export into the local projection store (`replaceExisting` optional) |

## Details UI

The messaging **Details** session section shows a click-to-copy Conversation ID.
For Lico-owned projections the local session id is preferred; for ordinary native
sessions the native session id is preferred. The same id is accepted by
`lico_conversation_get`.
