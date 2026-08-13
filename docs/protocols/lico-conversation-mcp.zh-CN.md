# LicoUp 对话 MCP

[English（规范版本）](lico-conversation-mcp.md) · 简体中文（本地化）

权威来源：`crates/licoup-native/src/bin/lico-conversation-mcp.rs` 与
`crates/licoup-native/src/domain/client_conversation/`。实现或验证变化时应同步更新本文档。

`lico-conversation-mcp` 是随桌面客户端打包的本地 stdio MCP 服务。它只读写私有
客户端状态中的 LicoUp 统一 Conversation 存储，绝不改写第三方智能体原生历史，也不
暴露私有原生续接位置。

服务名：`lico-up-conversations`。

## 工具

| 工具 | 用途 |
| --- | --- |
| `lico_conversation_list` | 最多列出 100 个统一 Conversation 摘要；除非明确请求，否则不含已归档 Conversation |
| `lico_conversation_get` | 按稳定 `conversationId` 读取一个 Conversation |
| `lico_conversation_search` | 通过有界全文索引检索结构化 Event 文本 |
| `lico_conversation_export` | 把指定或有界的全部统一 Conversation 导出到 JSON 包路径 |
| `lico_conversation_import` | 导入当前统一格式的 JSON 包，身份冲突时不覆盖 |

全部输入对象都是封闭且有界的。检索使用关键词/全文索引，不执行调用方提供的正则表达式。
导入导出只面向统一 Conversation schema；旧投影存储选项和原生会话标识不属于契约。

## 统一模型

单聊与群聊使用同一个 Conversation 模型。Human 与 Agent Principal 以对等 Membership
参与；访问权、成员生命周期、运行时可用性、协作 Role 与原生执行绑定是彼此独立的事实。

可见历史是有序的结构化 Event 流。Role 包含有序的候选 Agent Membership 池。
适应性飞轮由有序 Role 阶段组成，可按 `single`、`round-robin`、`all` 或
`bounded-parallel` 解析。运行在领取任务前冻结角色与候选快照，因此之后的编辑不会
改变正在执行的运行。

生成的 Conversation 桥接是应用层的变更、Event 分页、角色/飞轮编辑、运行启动/读取/
继续/取消、原子任务领取/状态转换及导入导出契约。MCP 刻意只暴露上面的有界管理子集。

## 隐私与迁移

原生运行时会话标识、续接位置及工作目录属于私有存储字段，不会出现在公开 Conversation、
MCP、导出包或生成桥接值中。一次性原生迁移会导入受支持的 LicoUp 自有旧状态、记录迁移
版本，并且只在校验成功后移除旧投影、单例群聊、TOML 飞轮及文件交接存储。遇到不受支持
且非空的旧 transcript 时会关闭失败，不会静默丢弃。
