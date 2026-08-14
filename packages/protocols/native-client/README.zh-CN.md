# packages/protocols/native-client

[English (normative)](README.md) · 简体中文本地化

本目录记录 LicoUp Flutter 客户端、Rust native library 与本机智能体之间的客户端内部
适配边界。这里的“稳定”不适用于
[当前正在退役的端点保护预览](../../../docs/STATUS.zh-CN.md)。

实现入口：

- `../../../crates/licoup-native/src/core/task_queue.rs`：有界本机任务队列。
- `../../../crates/licoup-native/src/platform/runtime_adapters.rs`：智能体会话适配注册表。
- `../../../crates/licoup-native/src/core/mcp.rs`：与服务实现无关的 MCP JSON-RPC 报文适配。
- `../../../crates/licoup-native/src/core/secure_mesh_acp.rs`：当前端点保护预览上的 ACP 承载。

协议范围：

- 并发发现本机智能体及其原生配置。
- 通过智能体官方 ACP、app-server、RPC 或 CLI 通道新建、续接和回显对话。
- 构造、校验和编码单条 MCP 请求、通知与响应；转发响应必须消费与请求和目的端精确绑定的一次性用户批准。
- 在当前端点保护预览消息内承载经过端到端保护的 ACP 命令和结果。
- macOS、Windows、Ubuntu、Android 与 iOS 的平台桥接只实现各自平台职责，不复制业务协议。

边界原则：

- CLI、Flutter 与移动桥接复用同一组 Rust 协议模型，不各自创建报文变体。
- 稳定、线上可观测的 Pairwise Protection、Generic Message、Reliable Exchange、
  协商与 Transport Profile 语义属于一条固定 Lico Arc Protocol Line。当前正在
  退役的预览不是 Lico Arc Profile，不承诺未来兼容；该线路替换它时会直接退役。
- LicoUp 保留私钥、Provider 配置、明文、历史、备份、用户信任、审批和本地效果。
- 本机路径、配置、对话和统计保留在客户端拥有的存储中。
- 任何把用户信息或文件发送到本机之外的动作都必须由用户针对本次动作、具体目的端和具体范围直接确认；取消、范围不匹配或批准缺失时失败关闭。
