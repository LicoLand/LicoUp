# Lico Arc 兼容性

[English（规范版本）](COMPATIBILITY.md) · 简体中文（本地化） · [文档索引](README.md) · [项目首页](../README.zh-CN.md)

产品版本：`0.0.1-alpha`

生成来源：`tools/client-support-matrix.json`、`tools/client-release-targets.json`、`tools/client-version.json`、`crates/lico-client-native/resources/agent-conversation-drivers.json` 和 `crates/lico-client-native/resources/agent-conversation-readiness.json`。

使用 `npm run client:support-matrix:sync` 更新，使用 `npm run client:support-matrix:check` 验证。请勿手工维护本投影。

## 平台目标

可以构建，不代表已经支持。

| 目标 | 构建 | 可选入 GitHub Release | 真机/设备证据 | 商店发布 | 客户端 | 对端加密 | 移动中转 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| windows-x64 | 可用 | 不可选入 | 未声明 | 未声明 | 预览 | 预览 | 预览 |
| windows-arm64 | 不可用 | 不可选入 | 未声明 | 未声明 | 未验证 | 未验证 | 未验证 |
| macos-x64 | 可用 | 不可选入 | 未声明 | 未声明 | 支持 | 预览 | 预览 |
| macos-arm64 | 可用 | 可选入 | 未声明 | 未声明 | 支持 | 预览 | 预览 |
| linux-glibc-x64 | 可用 | 不可选入 | 未声明 | 未声明 | 预览 | 预览 | 预览 |
| linux-glibc-arm64 | 可用 | 可选入 | 未声明 | 未声明 | 预览 | 预览 | 预览 |
| linux-musl-x64 | 可用 | 不可选入 | 未声明 | 未声明 | 预览 | 预览 | 预览 |
| linux-musl-arm64 | 可用 | 不可选入 | 未声明 | 未声明 | 预览 | 预览 | 预览 |
| android-arm64 | 可用 | 可选入 | 未声明 | 未声明 | 支持 | 预览 | 预览 |
| ios-simulator-arm64 | 可用 | 不可选入 | 仅模拟器 | 未声明 | 支持 | 预览 | 预览 |
| ios-arm64 | 不可用 | 不可选入 | 未声明 | 未声明 | 未验证 | 未验证 | 未验证 |

## 状态说明

- “支持”表示当前目标的客户端专项检查接受该功能，不代表已经具备分发条件。
- “预览”表示功能仍在变化。
- “未验证”表示当前没有支持声明。
- “不支持”表示界面不得把该功能显示为可用。
- “可选入”表示发布人员可以明确选择该目标，不表示任何当前发布已经包含它。
- 功能状态不能证明原生宿主、真机、生物识别、硬件密钥保管或跨设备证据；这些结论保持“未声明”，模拟器行只证明模拟器闭环。
- 本矩阵不声明商店发布；商店发布必须有独立的渠道结论。
- 对端内容由发送客户端加密，敏感运行时数据留在本机。

## 智能体适配目标

本表投影原生驱动清单。运行协议和能力字段仍由该清单负责。

| 智能体 ID | 驱动模式 | 就绪状态 | 可发送 | 运行协议 | 通道族 | 准确继续 | 流式事件 | 原生中断/steer |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| openclaw | conversation | unverified | 否 | openclaw-acp-stdio-jsonrpc | acp | 是 | 是 | 否 |
| claude-code | conversation | unverified | 否 | claude-code-cli-stream-json | stream-json | 是 | 是 | 是 |
| codex | conversation | unverified | 否 | codex-app-server-stdio-jsonrpc | app-server | 是 | 是 | 是 |
| antigravity | conversation | unverified | 否 | antigravity-cli-argv-hook-v1 | cli | 是 | 是 | 否 |
| opencode | conversation | unverified | 否 | opencode-serve-http-v1 | serve-http | 是 | 是 | 否 |
| copilot | conversation | unverified | 否 | copilot-acp-v1-stdio-ndjson | acp | 是 | 是 | 否 |
| kilo-code | conversation | unverified | 否 | kilo-code-serve-http-v1 | serve-http | 是 | 是 | 否 |
| cursor | conversation | unverified | 否 | cursor-agent-cli-v1 | cli | 是 | 是 | 否 |
| hermes | conversation | unverified | 否 | hermes-acp-stdio-jsonrpc | acp | 是 | 是 | 否 |
| kimi-code | conversation | unverified | 否 | kimi-code-acp-v1-stdio-ndjson | acp | 是 | 是 | 否 |
| pi | conversation | unverified | 否 | pi-rpc-stdio-jsonl | rpc | 是 | 是 | 是 |
