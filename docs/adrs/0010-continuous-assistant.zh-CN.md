# ADR 0010：会话连续性的归属

Updated: 2026-09-25

[English](0010-continuous-assistant.md)

连续性记录属于 Canonical Conversation。提供者会话是可替换的执行绑定，不拥有历史、
成员关系或权限。因此，更换原生会话不会产生另一份用户约定存储，也不会扩大上下文
访问范围；代价是在持久属主与每个运行时之间显式维护绑定和对账。

[连续性边界](../architecture/CONTINUOUS-ASSISTANT.zh-CN.md)指向可执行 schema 和实现。
宿主状态与 Agent 自然回复分离；边界修改同时覆盖生产者与消费者。接口存在本身
不证明能力已可运行。
