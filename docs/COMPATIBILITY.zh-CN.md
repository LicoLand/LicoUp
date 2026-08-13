# LicoUp 兼容性

[English（规范版本）](COMPATIBILITY.md) · 简体中文（本地化） · [文档索引](README.md) · [项目首页](../README.zh-CN.md)

产品版本：`0.1.0`

生成来源：`tools/client-support-matrix.json`、`tools/client-release-targets.json`、`tools/client-version.json`、`crates/licoup-native/resources/agent-conversation-drivers.json`、`crates/licoup-native/resources/agent-native-capabilities.json` 和 `crates/licoup-native/resources/agent-conversation-readiness.json`。

使用 `npm run client:support-matrix:sync` 更新，使用 `npm run client:support-matrix:check` 验证。请勿手工维护本投影。

## 平台目标

可以构建，不代表已经支持。

| 运行目标 | 构建 | 真机/设备证据 | 客户端 | 对端加密 | 移动中转 |
| --- | --- | --- | --- | --- | --- |
| windows-x64 | 可用 | 未声明 | 预览 | 预览 | 预览 |
| windows-arm64 | 不可用 | 未声明 | 未验证 | 未验证 | 未验证 |
| macos-x64 | 可用 | 未声明 | 支持 | 预览 | 预览 |
| macos-arm64 | 可用 | 未声明 | 支持 | 预览 | 预览 |
| linux-glibc-x64 | 可用 | 未声明 | 预览 | 预览 | 预览 |
| linux-glibc-arm64 | 可用 | 未声明 | 预览 | 预览 | 预览 |
| linux-musl-x64 | 可用 | 未声明 | 预览 | 预览 | 预览 |
| linux-musl-arm64 | 可用 | 未声明 | 预览 | 预览 | 预览 |
| android-arm64 | 可用 | 未声明 | 支持 | 预览 | 预览 |
| ios-simulator-arm64 | 可用 | 仅模拟器 | 支持 | 预览 | 预览 |
| ios-arm64 | 不可用 | 未声明 | 未验证 | 未验证 | 未验证 |

## 发布包目标

运行目标和发布包目标是有意分离的两套权威。下表每一行只代表一个分发渠道的一种原生包；同时选择多行时，会生成多个相互独立的发布包目录。

| 发布包目标 | 运行目标 | 平台 | 渠道 | 格式 | 架构 | 包构建 | 可发布 | 更新权威 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| macos-direct-arm64 | macos-arm64 | macos | direct | dmg | arm64 | 可用 | 不可选入 | signed-http-manifest |
| macos-direct-x64 | macos-x64 | macos | direct | dmg | x64 | 可用 | 不可选入 | signed-http-manifest |
| macos-app-store-arm64 | macos-arm64 | macos | app-store | pkg | arm64 | 可用 | 不可选入 | store-managed |
| windows-direct-x64 | windows-x64 | windows | direct | msix | x64 | 可用 | 不可选入 | appinstaller |
| windows-store-x64 | windows-x64 | windows | microsoft-store | msixupload | x64 | 可用 | 不可选入 | store-managed |
| linux-deb-arm64 | linux-glibc-arm64 | linux | apt-repository | deb | arm64 | 可用 | 不可选入 | package-repository |
| linux-deb-x64 | linux-glibc-x64 | linux | apt-repository | deb | x64 | 可用 | 不可选入 | package-repository |
| linux-rpm-arm64 | linux-glibc-arm64 | linux | rpm-repository | rpm | arm64 | 可用 | 不可选入 | package-repository |
| linux-rpm-x64 | linux-glibc-x64 | linux | rpm-repository | rpm | x64 | 可用 | 不可选入 | package-repository |
| linux-pacman-x64 | linux-glibc-x64 | linux | pacman-repository | pkg.tar.zst | x64 | 可用 | 不可选入 | package-repository |
| linux-pacman-arm64 | linux-glibc-arm64 | linux | pacman-repository | pkg.tar.zst | arm64 | 可用 | 不可选入 | package-repository |
| linux-alpine-apk-arm64 | linux-musl-arm64 | linux | alpine-repository | apk | arm64 | 可用 | 不可选入 | package-repository |
| linux-alpine-apk-x64 | linux-musl-x64 | linux | alpine-repository | apk | x64 | 可用 | 不可选入 | package-repository |
| linux-appimage-arm64 | linux-glibc-arm64 | linux | direct | appimage | arm64 | 可用 | 不可选入 | appimage-update-information |
| linux-appimage-x64 | linux-glibc-x64 | linux | direct | appimage | x64 | 可用 | 不可选入 | appimage-update-information |
| android-direct-arm64-v8a | android-arm64 | android | direct | apk | arm64-v8a | 可用 | 可选入 | manual-download |
| android-play-arm64-v8a | android-arm64 | android | google-play | aab | arm64-v8a | 可用 | 不可选入 | store-managed |
| ios-app-store-arm64 | ios-arm64 | ios | app-store | ipa | arm64 | 可用 | 不可选入 | store-managed |

## 状态说明

- “支持”表示当前目标的客户端专项检查接受该功能，不代表已经具备分发条件。
- “预览”表示功能仍在变化。
- “未验证”表示当前没有支持声明。
- “不支持”表示界面不得把该功能显示为可用。
- “可选入”表示发布人员可以明确选择该精确发布包目标，不表示任何当前发布已经包含它。
- 通用 Linux 压缩包只可作为内部验证载体，不是可安装发布包；Linux 分发必须使用原生包或软件仓库目标。
- 功能状态不能证明原生宿主、真机、生物识别、硬件密钥保管或跨设备证据；这些结论保持“未声明”，模拟器行只证明模拟器闭环。
- 本矩阵不声明商店发布；商店发布必须有独立的渠道结论。
- 对端内容由发送客户端加密，敏感运行时数据留在本机。

## 智能体适配目标

本表投影原生驱动清单。运行协议和能力字段仍由该清单负责。
生命周期证据列表示该通道是否能为对应阶段发出原生回执。“已发送”始终是客户端本地事实。每一轮中，界面只展示实际观测到的回执；不支持或未到达的阶段直接跳过，不得通过后续回复或终态结果倒推。

| 智能体 ID | 驱动模式 | 就绪状态 | 可发送 | 运行协议 | 通道族 | 准确继续 | 流式事件 | GUI 退出后续跑 | 活动轮次重附着 | 有序游标重放 | 已接收证据 | 处理中证据 | 回复中证据 | 已完成证据 | 原生中断/steer |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| openclaw | conversation | unverified | 否 | openclaw-acp-stdio-jsonrpc | acp | 是 | 是 | 是 | 是 | 是 | 是 | 是 | 是 | 是 | 否 |
| claude-code | conversation | unverified | 否 | claude-code-cli-stream-json | stream-json | 是 | 是 | 是 | 是 | 是 | 是 | 是 | 是 | 是 | 是 |
| codex | conversation | unverified | 否 | codex-app-server-stdio-jsonrpc | app-server | 是 | 是 | 是 | 是 | 是 | 是 | 是 | 是 | 是 | 是 |
| antigravity | conversation | unverified | 否 | antigravity-cli-argv-hook-v1 | cli | 是 | 是 | 是 | 是 | 是 | 是 | 否 | 是 | 是 | 否 |
| opencode | conversation | unverified | 否 | opencode-serve-http-v1 | serve-http | 是 | 是 | 是 | 是 | 是 | 是 | 否 | 是 | 是 | 否 |
| copilot | conversation | unverified | 否 | copilot-acp-v1-stdio-ndjson | acp | 是 | 是 | 是 | 是 | 是 | 是 | 是 | 是 | 是 | 否 |
| kilo-code | conversation | unverified | 否 | kilo-code-serve-http-v1 | serve-http | 是 | 是 | 是 | 是 | 是 | 是 | 否 | 是 | 是 | 否 |
| cursor | conversation | unverified | 否 | cursor-agent-cli-v1 | cli | 是 | 是 | 是 | 是 | 是 | 是 | 否 | 是 | 是 | 否 |
| hermes | conversation | unverified | 否 | hermes-acp-stdio-jsonrpc | acp | 是 | 是 | 是 | 是 | 是 | 是 | 是 | 是 | 是 | 否 |
| kimi-code | conversation | unverified | 否 | kimi-code-acp-v1-stdio-ndjson | acp | 是 | 是 | 是 | 是 | 是 | 是 | 是 | 是 | 是 | 否 |
| pi | conversation | unverified | 否 | pi-rpc-stdio-jsonl | rpc | 是 | 是 | 是 | 是 | 是 | 是 | 是 | 是 | 是 | 是 |
| lico-agent | conversation | unverified | 否 | lico-agent-rpc-stdio-jsonl | rpc | 是 | 是 | 是 | 是 | 是 | 是 | 是 | 是 | 是 | 是 |

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
| lico-agent | CLI, RPC | rpc | stdio JSONL | 无 | 直接进程接口 |

## 手动虚拟机对话传输

桌面端手动目标流程可以通过系统 OpenSSH stdio 与 ACP，把 OpenClaw 或 Hermes 绑定到用户自有虚拟机。它要求已有严格主机校验和非交互 SSH 认证；LicoUp 不接受 SSH 密码或私钥。对话历史使用 ACP 会话列出/加载，而不是访问虚拟机文件系统。此源码传输能力本身不会提升上表中的适配器就绪状态或发布可发送声明。
