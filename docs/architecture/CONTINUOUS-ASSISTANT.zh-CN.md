# 会话连续性边界

Updated: 2026-09-25

[English](CONTINUOUS-ASSISTANT.md) · [会话模块](../modules/conversation.md)

Canonical Conversation 拥有持久历史、成员关系和连续性记录。运行时会话只是私有绑定，
不另建历史或目标权威。子任务使用已接纳的子会话和限定的父上下文授权；切换模型不扩大
接收者权限。上下文合成使用当前授权及撤权代次。视图脱离不等于取消或删除。

可执行字段以[会话 schema](../../schemas/client_bridge/conversation.json)为准，生成的
Rust/Dart 类型只是投影。[连续性实现](../../crates/licoup-conversation/src/continuity/)
拥有接纳、生命周期、存储端口和不支持能力的返回。接口存在不等于自动化能力已可用。

Agent 怎么回复就怎么展示，不强制回复格式。宿主状态来自观察和授权操作，不能要求
Agent 回复遵守宿主记录的结构。未知外部效果留待对账，不当成未发生而直接重试。

改变边界的设计必须包括会话、运行时及相关 UI/桥属主。运行 `npm run verify:conversation`
和受影响消费者的模块命令；通过 `npm run repo:state-machines -- --list` 查询状态机，
不在本文复制状态表。
