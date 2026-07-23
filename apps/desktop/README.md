# Lico Arc Desktop Client

Lico Arc 是本地优先的开源桌面与移动客户端。产品范围以
[`PRODUCT.md`](../../PRODUCT.md) 和
[`CLIENT-DESKTOP.md`](../../docs/functionality/CLIENT-DESKTOP.md) 为准；默认使用不依赖
LicoMesh 服务端。

## 默认产品范围

客户端内置四类基础能力：

- Rust 轻量本机任务队列；
- 本机智能体执行及加密远程中转所需的 ACP 适配；
- MCP 请求与返回报文转发适配；
- macOS、Windows、Ubuntu、Android 和 iOS 平台适配。

默认界面只承载以下用户场景：

- `Agents`：并发发现本机智能体、创建或继续原生对话；
- `Conversations`：检索、管理并备份全部或关键词命中的原生对话；
- `Skill Hub`：按智能体管理技能、从显式镜像或 GitHub 来源更新、删除及统计调用频率；
- `Usage`：按智能体或模型统计 Token，用最近 30 天作为默认窗口；
- `Mobile Relay`：在桌面与移动端之间传递端到端加密的不透明信封；
- `Settings`：本机设置、平台授权和外部传输审批。

ACP 与 MCP 是内置协议适配基础，不占用独立导航入口。可选 LicoMesh 协作只能通过下述
默认关闭的外部插件进入。

当前打包目标包括 Antigravity、Claude Code、Codex、Cursor、Copilot、Hermes、
Kilo Code、Kimi Code、OpenClaw、OpenCode 和 Pi Agent。发现到目标、读取到历史或
通过合成测试均不代表已支持对话；只有通过原生对话等价验收的 adapter 才能启用发送。
当前适配状态由原生驱动与 readiness 清单负责，并投影到
[`docs/COMPATIBILITY.md`](../../docs/COMPATIBILITY.md)；未就绪 adapter 必须保持
fail closed。

## 可选 LicoMesh 协作插件

LicoMesh 协作能力默认不加载，也不出现在默认启动路径。用户必须先手动启用，再从其
指定的 GitHub 来源安装可选插件。该插件只能提供：

1. 将 LicoMesh 下载到本机私有部署，并让用户在安装前选择服务端功能或插件；
2. 由用户手动触发，把选中的 LicoMesh MCP 插件安装到一个或多个本机智能体。

插件不得因安装、启动、定时任务或智能体请求而自动传出本机数据。涉及本机文件时，
每个文件都要单独展示目标、用途、范围与摘要，取得用户本次直接审批后才能发送；目标、
范围或内容变化会使审批失效，取消、过期或无法验证时必须 fail closed。

## 本机数据边界

本机路径、配置、对话、用量、诊断、设备事实和文件默认只保存在客户端本机。任何将
这些信息发送到当前设备之外的动作都必须由用户逐次发起或直接审批，提交前可取消，
且不能复用历史审批。用户点击发送一条已明确目标的端到端加密消息，只授权该消息和
该目标。

## 本机智能体对话

对话优先通过智能体官方协议、SDK 或结构化 CLI 创建并继续同一个原生会话。适配器必须
保留原生会话身份、有效模型与权限设置、事件顺序、最终结果和错误语义。若原生接口不
支持执行中注入，客户端可以实时回显当前轮过程，但必须等该轮完成后再启动下一轮。

连续的 progress、tool、result 和 error 事件在界面中收敛为一个默认折叠的过程项。
展开后也只能显示脱敏摘要，不得显示原始思维链、工具参数、凭据、原生标识或本机路径。

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

只有所有模块快测与定向验收均确认有效后，才执行一次完整客户端回归：

```bash
npm run client:verify
```

不要在开发过程中反复执行完整回归。架构、ACP/MCP、对话、技能、用量、备份、Secure
Mesh 和各平台适配分别使用模块目录登记的专属回归入口。

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
或证明及公开验证材料，不包含用户或客户端运行信息。
