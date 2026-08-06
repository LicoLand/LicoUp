# LicoUp 对话 MCP

[English](lico-conversation-mcp.md) · 简体中文

权威来源：`crates/licoup-native/src/bin/lico-conversation-mcp.rs` 与
`domain/owned_conversations/`。实现或验证变更时同步更新本投影。

`lico-conversation-mcp` 是随桌面客户端打包的**本地 stdio MCP 服务**。它只查询
**LicoUp 自有**对话：父进程投影库
（`{portable}/client-state/agent-conversation-projections.json`）与默认 Lico
群聊房间。它**不会**改写第三方智能体原生历史。

服务名：`lico-up-conversations`。

## 工具

| 工具 | 用途 |
| --- | --- |
| `lico_conversation_list` | 有界摘要列表 |
| `lico_conversation_get` | 按本地 `id` 或 `nativeSessionId` 精确查询 |
| `lico_conversation_search` | `matchMode=keyword`（默认）或 `regex`，匹配标题、ID、路径与消息正文 |
| `lico_conversation_export` | 导出 JSON 包到绝对路径（`conversationIds` 可选） |
| `lico_conversation_import` | 将导出包合并进本地投影库（`replaceExisting` 可选） |

## 详情 UI

消息区右上角**详情**的会话区提供可点击复制的会话 ID。Lico 自有投影优先本地
会话 id；普通原生会话优先原生会话 id。同一 id 可供 `lico_conversation_get` 使用。
