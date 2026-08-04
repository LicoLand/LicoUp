# LicoUp 兼容性

[English（规范版本）](COMPATIBILITY.md) · 简体中文（本地化） · [文档索引](README.md) · [项目首页](../README.zh-CN.md)

产品版本：`0.1.0-alpha`

生成来源：`tools/client-support-matrix.json`、`tools/client-release-targets.json`、`tools/client-version.json`、`crates/licoup-native/resources/agent-conversation-drivers.json`、`crates/licoup-native/resources/agent-native-capabilities.json` 和 `crates/licoup-native/resources/agent-conversation-readiness.json`。

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
生命周期证据列表示该通道是否能为对应阶段发出原生回执。“已发送”始终是客户端本地事实。每一轮中，界面只展示实际观测到的回执；不支持或未到达的阶段直接跳过，不得通过后续回复或终态结果倒推。

| 智能体 ID | 驱动模式 | 就绪状态 | 可发送 | 运行协议 | 通道族 | 准确继续 | 流式事件 | 已接收证据 | 处理中证据 | 回复中证据 | 已完成证据 | 原生中断/steer |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| openclaw | conversation | unverified | 否 | openclaw-acp-stdio-jsonrpc | acp | 是 | 是 | 是 | 是 | 是 | 是 | 否 |
| claude-code | conversation | unverified | 否 | claude-code-cli-stream-json | stream-json | 是 | 是 | 是 | 是 | 是 | 是 | 是 |
| codex | conversation | ready | 是 | codex-app-server-stdio-jsonrpc | app-server | 是 | 是 | 是 | 是 | 是 | 是 | 是 |
| antigravity | conversation | unverified | 否 | antigravity-cli-argv-hook-v1 | cli | 是 | 否 | 否 | 否 | 否 | 是 | 否 |
| opencode | conversation | unverified | 否 | opencode-serve-http-v1 | serve-http | 是 | 是 | 是 | 否 | 是 | 是 | 否 |
| copilot | conversation | unverified | 否 | copilot-acp-v1-stdio-ndjson | acp | 是 | 是 | 是 | 是 | 是 | 是 | 否 |
| kilo-code | conversation | unverified | 否 | kilo-code-serve-http-v1 | serve-http | 是 | 是 | 是 | 否 | 是 | 是 | 否 |
| cursor | conversation | unverified | 否 | cursor-agent-cli-v1 | cli | 是 | 是 | 是 | 否 | 是 | 是 | 否 |
| hermes | conversation | unverified | 否 | hermes-acp-stdio-jsonrpc | acp | 是 | 是 | 是 | 是 | 是 | 是 | 否 |
| kimi-code | conversation | unverified | 否 | kimi-code-acp-v1-stdio-ndjson | acp | 是 | 是 | 是 | 是 | 是 | 是 | 否 |
| pi | conversation | unverified | 否 | pi-rpc-stdio-jsonl | rpc | 是 | 是 | 是 | 是 | 是 | 是 | 是 |

## 原生能力清单

本表与桌面运行时使用同一份原生能力清单生成。

判断标准：

- 只列智能体自身提供的接口；LicoUp 管理的桥接或 `lico-llm-gateway` 不属于智能体原生能力。
- `CLI` 是普通命令进程；`acp`、`serve`、`web`、`gateway`、`app-server` 或 RPC 模式等协议子命令必须作为互斥的独立运行能力。
- `ACP`、`RPC` 和 `App Server` 是结构化进程协议，不代表存在网络监听端口。
- `Local Server` 是智能体直接提供的回环 API；`Web Server` 还拥有浏览器界面或更完整的 Web 控制面。
- `Gateway` 是客户端协议进程与智能体运行时之间可复用的中间附着层；`TUI Gateway` 是 Hermes 的远程/手动虚拟机特化入口。
- “已检测”表示所属可执行程序能够提供该能力；“运行中”必须匹配对应进程，网络 Server 或网络 Gateway 还必须具备自身监听证据。

| 智能体 ID | 原生能力 | LicoUp 主通道 | 主传输 | 监听 | 定位 |
| --- | --- | --- | --- | --- | --- |
| openclaw | CLI, ACP, Gateway | acp | stdio ACP | 回环 TCP | 中间附着层 |
| claude-code | CLI | stream-json | stdio stream-json | 无 | 直接进程接口 |
| codex | 桌面端, CLI, App Server | app-server | stdio JSON-RPC | 无 | 直接 stdio App Server |
| antigravity | 桌面端, CLI | cli | CLI 进程 | 无 | 直接进程接口 |
| opencode | CLI, Local Server | serve-http | 回环 HTTP + SSE | 回环 TCP | 直接本地智能体 API |
| copilot | CLI, ACP | acp | stdio ACP | 无 | 直接进程接口 |
| kilo-code | CLI, Local Server | serve-http | 回环 HTTP + SSE | 回环 TCP | 直接本地智能体 API |
| cursor | 桌面端, CLI | cli | CLI 进程 | 无 | 直接进程接口 |
| hermes | CLI, ACP, TUI Gateway | acp | stdio ACP | 仅条件式远程连接 | ACP 直连；TUI Gateway 仅用于手动虚拟机 |
| kimi-code | CLI, ACP, Web Server | acp | stdio ACP | 回环 TCP | 直接控制面与 Web UI |
| pi | CLI, RPC | rpc | stdio JSONL | 无 | 直接进程接口 |

## 手动虚拟机对话传输

桌面端手动目标流程可以通过系统 OpenSSH stdio 与 ACP，把 OpenClaw 或 Hermes 绑定到用户自有虚拟机。它要求已有严格主机校验和非交互 SSH 认证；LicoUp 不接受 SSH 密码或私钥。对话历史使用 ACP 会话列出/加载，而不是访问虚拟机文件系统。此源码传输能力本身不会提升上表中的适配器就绪状态或发布可发送声明。
