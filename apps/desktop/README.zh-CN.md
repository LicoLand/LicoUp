# LicoUp Desktop Client

[English (normative)](README.md) · 简体中文本地化

LicoUp 是本地优先的开源桌面与移动客户端。产品范围以
[`PRODUCT.md`](../../PRODUCT.md) 和
[`CLIENT-DESKTOP.md`](../../docs/functionality/CLIENT-DESKTOP.md) 为准。

## 默认产品范围

客户端内置四类基础能力：

- Rust 轻量本机任务队列；
- 本机智能体执行及加密远程中转所需的 ACP 适配；
- MCP 请求与返回报文转发适配；
- macOS、Windows、Ubuntu、Android 和 iOS 平台适配。

默认界面只承载以下用户场景：

- `Agents`：并发发现本机智能体，并与本机或明确配置的 OpenClaw/Hermes
  虚拟机目标创建、列出或继续原生对话；
- `Conversations`：检索、管理并备份全部或关键词命中的原生对话；
- `Skill Hub`：按智能体发现和展示本机已有技能、统计调用频率，并把选中的技能移入系统废纸篓；
- `Usage`：按智能体或模型统计 Token，用最近 30 天作为默认窗口；
- `Mobile Relay`：在桌面与移动端之间传递端到端加密的不透明信封；
- `Settings`：本机设置、平台授权和外部传输审批。

ACP 与 MCP 是内置协议适配基础，不占用独立导航入口。

`Mobile Relay` 当前执行[正在退役的端点保护预览](../../docs/STATUS.zh-CN.md)，
并通过已实现的候选 `licoarc.relay.v1` 外层 adapter 承载。该预览不是 Lico Arc
Profile，也不承诺未来兼容。稳定客户端将执行一条固定 Lico Arc Protocol Line
的线上可观测 Pairwise Protection、Generic Message、Reliable Exchange、协商与
Transport Profile 语义，同时继续拥有自己的私钥、Provider 配置、明文、历史、
备份、信任决定、审批和本地效果。

当前打包目标包括 Antigravity、Claude Code、Codex、Cursor、Copilot、Hermes、
Kilo Code、Kimi Code、OpenClaw、OpenCode 和 Pi Agent。发现到目标、读取到历史或
通过合成测试均不代表已支持对话；只有通过原生对话等价验收的 adapter 才能启用发送。
当前适配状态由原生驱动与 readiness 清单负责，并投影到
[`docs/COMPATIBILITY.md`](../../docs/COMPATIBILITY.md)；未就绪 adapter 必须保持
fail closed。

## 本机数据边界

本机路径、配置、对话、用量、诊断、设备事实和文件默认只保存在客户端本机。任何将
这些信息发送到当前设备之外的动作都必须由用户逐次发起或直接审批，提交前可取消，
且不能复用历史审批。用户点击发送一条已明确目标的端到端加密消息，只授权该消息和
该目标。对于手动配置的虚拟机目标，对话页持续显示 SSH 目标；点击发送只授权把该条
提示交给虚拟机内选中的智能体。

## 智能体对话

对话优先通过智能体官方协议、SDK 或结构化 CLI 创建并继续同一个原生会话。适配器必须
保留原生会话身份、有效模型与权限设置、事件顺序、最终结果和错误语义。若原生接口不
支持执行中注入，客户端可以实时回显当前轮过程，但必须等该轮完成后再启动下一轮。

每条用户消息下方只展示一个本轮生命周期，并与连续的思考和工具活动合并。普通提供方
记账事件会收敛为低强调的运行记录行，不再伪装成另一个过程卡片。展开后也只能显示
脱敏摘要，不得显示原始思维链、工具参数、凭据、原生标识或本机路径。

桌面端允许为 OpenClaw 或 Hermes 添加虚拟机 SSH 目标。客户端只保存主机、可选端口/
用户、虚拟机内程序和绝对工作目录，不接受密码或私钥。Rust 通过系统 OpenSSH 的严格
主机校验与非交互认证启动固定的 `openclaw acp` 或 `hermes acp`，并通过 ACP
列出、加载与继续会话；它不会读取或复制虚拟机内的历史数据库，也不会把本机 MCP
服务描述转发到虚拟机。

## 开发

```bash
npm run client:get
npm run client:analyze
npm run client:test
npm run client:native:test
```

启动桌面端或移动端：

```bash
npm run client:run:macos
npm run client:run:android -- --debug
npm run client:run:ios -- --debug
```

依赖、Gradle 和 Flutter 缓存必须位于源码树之外。需要覆盖缓存位置时使用项目支持的
`LICO_CLIENT_*_CACHE` 环境变量，并用 `<cache-root>` 一类占位路径，不把工作站路径写入
文档、日志或证据。

## 最小回归闭环

开发期先选择受影响模块：

```bash
npm run client:regression:list
npm run client:regression -- --changed-from <ref> --dry-run
npm run client:regression -- --module <module-id>
```

所有模块快测与定向验收均确认有效后，运行一次必需的源码策略，并且只运行受影响的
技术通道：

```bash
npm run client:gate:source
npm run client:gate:flutter         # 仅 Flutter 改动
npm run client:gate:rust            # 仅 Rust 改动
npm run client:gate:android         # 仅 Android 改动
npm run client:gate:dependencies    # 仅依赖改动
npm run client:gate:release-policy  # 仅发布策略改动
```

源码策略只需要 Node，不安装 Flutter、Rust 或 Android 工具链。各技术通道彼此独立并
可并行；不要串联未受影响平台。架构、ACP/MCP、对话、技能、用量、备份、端点保护
和各平台适配分别使用模块目录登记的专属回归入口。

## 构建与打包

```bash
npm run client:package:plan
npm run client:build:macos
npm run client:build:windows
npm run client:build:linux
npm run client:build:android
```

macOS、Windows、Ubuntu、Android 和 iOS 的构建、普通验证、GitHub Release 以及各平台
商店发布是互相独立的声明。缺少某个商店的发布身份或签名条件，只阻断该渠道，不阻断
源码开发、普通构建或其它已验证平台。公开制品只包含消费者验证所需的最小摘要、签名
或证明及公开验证材料，不包含用户或客户端运行信息。每次 GitHub Release 调度只选择
一个受支持目标；不同目标可并行构建，仅同一标签的资产清单追加操作短暂串行。
