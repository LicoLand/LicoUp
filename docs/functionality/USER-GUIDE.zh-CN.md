# LicoUp 用户指南

[English（规范版本）](USER-GUIDE.md) · 简体中文（本地化） · [文档索引](../README.md) · [项目首页](../../README.zh-CN.md)

LicoUp 仍处于早期 Alpha 阶段。在重要场景中使用某个平台或功能前，请先查看
[兼容性状态](../COMPATIBILITY.zh-CN.md)。

## 启动客户端

请先安装 Node.js 22 或 24、Flutter stable 和 Rust stable，然后运行：

```bash
npm ci
npm run client:get
```

常用启动和构建命令：

```bash
npm run client:run:macos
npm run client:run:android
npm run client:run:ios
npm run client:build:macos
npm run client:build:linux
npm run client:build:windows
npm run client:build:android
```

存在构建命令，不代表对应平台已经完整支持。

## 使用本机智能体

1. 打开 **Agents**。
2. 让 LicoUp 查找设备上已安装并受支持的智能体。
3. 选择一个智能体。
4. 新建对话；如果适配器支持，也可以继续已有对话。

智能体历史、设置和进程信息保留在本机。界面只显示安全摘要，不直接展示原始工具
输入、凭据或本地路径。

在 Messaging 桌面智能体界面中，对话输入区上方的玻璃胶囊承载次要运行时控制：

- **工作区** — 下一轮使用的目录。优先沿用所选对话在原生历史中的项目路径；新建
  时请选择具体项目目录。家目录、影音图库等个人树根会被拒绝，以免智能体索引整棵
  目录树。
- **模型 / 思考强度** — 打开运行时胶囊，**模型**与**思考强度**为并列两行。模型
  留在 **自动** 时使用该智能体的原生默认；思考强度选项跟随有效模型（已选模型，
  或自动时的原生默认）。

将指针移到右上角的对话、详情或通知控件上，可打开贴着图标锚定的悬浮玻璃卡片；
没有对话详情侧栏。

发现流程会探测当前平台对应的应用来源，包括包管理器以及常见的可执行文件和配置位置。
探测采用固定上限的并发，归一化后的路径和配置引用只缓存在客户端，后续启动无需每次
完整扫描。

继续对话时，LicoUp 优先调用智能体原生的接入或恢复能力。如果适配器不能在智能体
执行中接收输入，客户端会继续实时投影输出，并在本轮回复完成后才启动下一轮。

**Cursor** 发送始终走 Agent CLI（`cursor-agent`），不是 Cursor 应用内的 IDE Agent
面板。IDE 对话与 CLI 对话分属不同存储，CLI 的 `--resume` 不会加载 IDE 历史。
当你在 LicoUp 中继续一条 IDE 来源的 Cursor 对话时，首次发送会新建 CLI 会话，并
一次性注入交接信息：IDE composer id、`state.vscdb` 路径与 key 前缀、以及 IDE
侧最后一次助手回复，其后才是你的消息。之后在该 CLI 会话上的发送按正常续聊，
不再重复交接。

顶部联系人 **Lico** 打开 LicoUp 自有的**群聊 Conversation**，每个智能体都是对等
参与者。输入框上方提供工作空间胶囊、显示**当前对话**智能体的飞轮胶囊，以及圆形
编辑按钮。悬停飞轮胶囊可选择智能体及其模型（Lico Agent 使用 Gateway 供应商 A–Z；
第三方使用各自原生模型目录）。点击胶囊或编辑按钮打开完整适应性飞轮编辑器。

**Lico Agent** 是智能体列表中的独立自研运行时（不是群聊入口本身）。与其对话时可
选择 Agent 或 Plan 模式；Plan 模式在操作系统沙盒下仅能写入绑定的本地计划文件。
详见 [Lico Agent](../protocols/lico-agent.zh-CN.md)。

打开**适应性飞轮**可配置日常对话和交付 route 表。飞轮是唯一的 route 选择权威：
每个交付角色与难度解析为一个 agent、model 和 reasoning effort，LicoUp 会把决定冻结
在 dispatch receipt 中。即使可选适配器插件已就绪，交付归属仍由 LicoUp 原生调度器掌握。

原生交付调度器消费持久化 Plan 与 Checkpoints，获取完整 eligible frontier，保持稳定
顺序和有界原生通道，并且只在终态结算后推进 checkpoint。MCP 调用方只能启动、授权、
查看或显式取消工作流；不能提交 Task、选择 route、绑定对话或接受 Reviewer。不同工作流
可以并发执行，同一工作流和 Task attempt 保持有序。

日常对话选择仍由 Assistant 配置控制，其模型和思考强度控制与交付角色 route 分离。
修改 route 后请保存适应性飞轮，原生调度器会读取新的持久化状态；客户端不会暴露状态
文件或可执行文件路径。

## 连接虚拟机内的 OpenClaw 或 Hermes

此桌面流程面向用户自己控制的虚拟机。请先在虚拟机内安装并配置 OpenClaw 或 Hermes；
OpenClaw 的 ACP 命令还必须能够连接虚拟机内已配置的 Gateway。

保持本机 OrbStack 虚拟机运行并打开**智能体**页面。LicoUp 会自动检查 `PATH` 中
的可执行文件及以下安装位置族：

- OpenClaw：`~/.openclaw` 安装器前缀、`~/.local/bin` 用户包装器、常见
  npm/pnpm/Bun/Volta/Nix 用户 bin 目录及系统 bin 目录。
- Hermes：`~/.local/bin`、`~/.hermes/hermes-agent/venv` 安装器虚拟环境、
  Hermes/Nix 用户 bin 目录及系统 bin 目录。

这些位置对应
[OpenClaw 安装器](https://docs.openclaw.ai/install/installer)和
[Hermes 安装指南](https://github.com/NousResearch/hermes-agent/blob/main/website/docs/getting-started/installation.md)。
对于 Hermes，LicoUp 会先检查可选 ACP 包；未安装该附加包的默认 Hermes 安装会
自动改用 Hermes
[内置 TUI Gateway JSON-RPC](https://github.com/NousResearch/hermes-agent/blob/main/website/docs/developer-guide/programmatic-integration.md)，
不会在虚拟机内安装或修改任何内容。选择自动发现的虚拟机目标后，可以列出会话、
打开已有会话或新建对话。

对于非 OrbStack 虚拟机或非标准安装：

1. 使用系统 OpenSSH 为虚拟机配置密钥或 agent 认证，并把主机密钥加入系统
   `known_hosts`。LicoUp 强制主机校验与非交互认证，因此不会弹出密码、私钥或首次
   连接信任输入框。
2. 选择**添加目标**，再选择 **OpenClaw** 或 **Hermes**。
3. 把**运行位置**设为**虚拟机（SSH）**。
4. 输入虚拟机主机名、可选 SSH 端口和用户、虚拟机内的程序名或绝对程序路径，以及
   一个以 `/` 开头的虚拟机绝对工作目录。
5. 添加并选择目标。

发送前，对话页会显示准确的 SSH 目标。

LicoUp 通过系统 SSH 客户端启动 `openclaw acp` 或 `hermes acp`，并使用 ACP
`session/list`、`session/load` 以及原生新建/提示生命周期。它不会读取或复制虚拟机
内的私有历史数据库。目标字段不接受密码或私钥，本机 MCP 服务描述不会转发到虚拟机，
自动及手动虚拟机连接也不会进入快速发现缓存。用户点击**发送**后，选中的虚拟机智能体
会通过已认证的 SSH 传输收到该条准确提示。

## 管理智能体适配插件

从桌面端导航打开**插件管理**，可以检查全部随客户端打包的智能体适配器。
Native Support 和 Native ACP 无需额外安装。当目标不属于这两类时，由
LicoUp Adaptive Bridge 负责针对该目标的交互适配。只有目录条目声明了真实的
生命周期操作时，页面才会显示安装或卸载。每个桥接操作都需要直接确认，
并且只能修改 LicoUp 自有文件或命名空间 Hook。发现或安装成功本身不代表
智能体已经可以对话。插件就绪状态始终与原生交付归属和适应性飞轮 route 权威分开报告。

## 管理本地数据

- 技能只在设备上安装和管理。更新只使用用户已经配置的镜像源或 GitHub 仓库；只有用户
  明确启用计划后才会自动检查。删除技能时必须准确指定一个或多个目标智能体。
- 技能使用次数来自真实的本机调用事件，可按时间窗口查看；浏览或安装技能不计为使用。
- 对话备份写入用户选择的本地目录。启动本地备份任务前，可选择全部对话或准确关键词，
  并先检查预览结果。
- Token 用量视图根据本地记录计算，默认窗口为最近 30 天；也可以选择按智能体、模型或
  工作流统计，并指定自定义时间窗口。工作流视图按原生 Plan → Task → dispatch 展开，
  展示精确覆盖率和主对话与下属对话拆分，数据仅来自数字 ledger。LicoUp 负责调度，
  Adaptive Flywheel 负责 route 选择，原生对话位置只作为私有交接传给适配器。视图不会
  暴露 prompt、reply、tool payload、摘要、压缩或 cache 控件；原生 ledger 只保留活动工作流
  和最新二十份终态汇总。
- 日志和诊断留在本机；用户可以主动保存一份脱敏副本。

不要在公开问题中附加原始日志、历史、本地路径或设备信息。

## 启用可选协作

Meshrix 协作是独立插件，默认客户端不会加载或查询它。

1. 打开**插件管理**中的协作插件区域。
2. 选择 GitHub 仓库和一个准确、不可变的提交。
3. 通过独立操作导入预期签名公钥，并完成系统身份验证。
4. 检查已签名的固定运行器、完整软件包清单、组件和本机目标，再手动安装并启用插件。
5. 如需本地部署，先组装选中的组件，再通过一次独立手动操作启动固定且已签名的外部
   运行器；组装不会自动启动服务端。可在同一区域停止或卸载。
6. 如需安装 MCP，选择一个或多个插件以及一个或多个本机智能体，应用前检查准确的本地
   改动。

LicoUp 源码树不包含 Meshrix 服务端运行器。因此，客户端构建成功不能证明已经获得
服务端制品，也不能证明已经启动本地部署。

安装或启用插件不会授予持续的数据传输权限。如果 MCP 操作需要访问外部服务，bridge 会
先创建一份不发起传输的预览。请在 LicoUp 中检查目标、用途、准确请求和每个选中文件，
完成平台身份验证，并且只批准本次操作。授权只能消费一次；文件、目标、用途、请求正文、
会话或消费方变化时都会失效，取消、过期或复用也会关闭失败。如果平台无法提供受保护的
身份验证，对外传输保持禁用。

## 预览发往另一个客户端的受保护传输

该流程使用[当前正在退役的端点保护预览](../STATUS.zh-CN.md)，可以通过候选
`licoarc.relay.v1` 外层 adapter 承载，并已有一项有界双全新端点场景通过实际
BadTower 候选完成本机验证。这不建立已发布 Lico Arc Protocol Line、稳定中立
通讯站支持、产品发布或托管运营。只应用于测试内容或用户明确接受的预览内容：

1. 选择接收内容的 LicoUp 客户端。
2. 检查具体消息或文件以及目标客户端。
3. 只批准这一次传输。
4. LicoUp 在发送设备上加密内容。
5. 接收客户端校验并解密。

LicoUp 不信任当前运输服务处理明文，只向它发送密文和完成本次传输所需的最少
路由信息。更换目标或修改内容后，必须重新确认。当前内层预览不是 Lico Arc
Profile，也不承诺未来兼容；完整固定 Lico Arc Protocol Line 替换它时会直接
退役。

## 校验发布文件

只使用项目发布页附带的文件。对照该次发布提供的公开校验信息，检查文件摘要和签名。
构建成功本身不代表已经完成发布。

如需了解客户端内部结构，请阅读[架构说明](../architecture/README.zh-CN.md)。
