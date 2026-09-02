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
npm run client:build -- --platform macos
npm run client:build -- --platform linux
npm run client:build -- --platform windows
npm run client:build -- --platform android
```

这个唯一构建入口会自动回收空闲的编译产物和临时 Flutter 构建缓存，同时保留可运行及
可打包产物供安装流程使用，包括 macOS Applications 安装流程。

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

发现流程只探测 Agent 扫描路径清单里的命名位置（各 Agent 的二进制、配置和历史目录），
不遍历 `PATH`，也不探测桌面、文稿、下载、图片、音乐或网络宗卷，启动时不会执行第三方
Agent 二进制；未使用智能体的扫描
不会打开其他 App 的容器。进入某个 Agent 的对话界面时，会从它的 CLI 或命名存储加载该 Agent
的模型列表。Token 用量在打开监测页时读取，不会在启动时扫描。探测采用固定上限的并发，归一化后的路径和配置引用只缓存在
客户端。

继续对话时，LicoUp 优先调用智能体原生的接入或恢复能力。如果适配器不能在智能体
执行中接收输入，客户端会继续实时投影输出，并在本轮回复完成后才启动下一轮。

**Cursor** 发送始终走 Agent CLI（`cursor-agent`），不是 Cursor 应用内的 IDE Agent
面板。IDE 对话与 CLI 对话分属不同存储，CLI 的 `--resume` 不会加载 IDE 历史。
当你在 LicoUp 中继续一条 IDE 来源的 Cursor 对话时，首次发送会新建 CLI 会话，并
一次性注入交接信息：IDE composer id、`state.vscdb` 路径与 key 前缀、以及 IDE
侧最后一次助手回复，其后才是你的消息。之后在该 CLI 会话上的发送按正常续聊，
不再重复交接。

统一群聊 Conversation 基础仍与 Agent 直接对话入口相互独立。Adaptive Flywheel
拥有自己的桌面策略界面：目录初始为空，只有导入 ZIP 包之后才会出现策略。策略导入、胶囊角色编辑器、后台运行时检测与工作流程图详见
[Adaptive Flywheel 策略](ADAPTIVE-FLYWHEEL.zh-CN.md)。

**Lico Agent** 是智能体列表中的独立自研运行时（不是群聊入口本身）。与其对话时可
选择 Agent 或 Plan 模式；Plan 模式在操作系统沙盒下仅能写入绑定的本地计划文件。
详见 [Lico Agent](../protocols/lico-agent.zh-CN.md)。

打开**适应性飞轮**可配置日常对话与 Assistant 工作流入口。飞轮是唯一的 route 选择权威：
每个工作流条目解析为一个 agent、model 和 reasoning effort，LicoUp 会把决定冻结在
run receipt 中。

Assistant 是在同一原生 Conversation 中对你的目标负责到底的长期属主。它要么自行完成，
要么提交一份带准确 Membership 绑定的有界临时 workflow Graph。Graph 在任何 Agent 效果
之前先编译并预检：结构、额度、model、Agent、Skill、环境与能力问题先返回稳定 typed
错误；readiness 与既有 Authority 问题也在效果前返回；无法预检的运行期失败返回给 Assistant，
它可以直接继续或编写后续 Graph。MCP
的四个 Assistant 工具负责 Profile 排序，以及临时工作流的执行（含内部预检与持久准入）、
查看和显式取消。MCP 绑定的 Agent 必须是准确且活动的指定 Assistant Membership；它不能
选择 route、绑定原生会话或创建隐藏参与者。不同工作流可以并发执行，每个工作流与
Membership turn 保持有序。

日常对话选择仍由 Assistant 配置控制，其模型和思考强度控制与 Adaptive Flywheel route
选择分离。修改 route 后请保存适应性飞轮，客户端会读取新的持久化状态；
客户端不会暴露状态文件、可执行文件路径或原生续接位置。

群聊输入框中的**自动适配**表示下一条消息通过与一对一聊天相同的原生通道发给指定
Assistant。导入策略是由 Assistant 控制的工作流工具，不会替换 Assistant。工作流拒绝会
标出失败 stage 和安全的请求位置；角色与 Assistant 的 model 目录通过一次后台 target
batch 加载。

DeepSeek Harness 通过官方 SDK JSON-RPC runtime carrier 纳入适配目标。当前声明文本会话、
准确 session 连续性、结构化流式事件与显式 model 选择；发布 readiness 仍为 unverified，
且本通道不声明 cancel、活动 prompt steer、历史回读、reasoning override 或多模态输入。

## 连接虚拟机内的 OpenClaw 或 Hermes

此桌面流程面向用户自己控制的虚拟机。请先在虚拟机内安装并配置 OpenClaw 或 Hermes；
OpenClaw 的 ACP 命令还必须能够连接虚拟机内已配置的 Gateway。

保持本机 OrbStack 虚拟机运行并打开**智能体**页面。LicoUp 按 Agent 扫描路径清单
检查这些安装位置族：

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
智能体已经可以对话。插件就绪状态始终与原生 Assistant 工作流和适应性飞轮 route 权威分开报告。

可选协作始终位于默认客户端之外。安装或启用不会授予持续传输权限；组装不会自动启动服务端。
导入签名公钥、组装固定签名运行器、在 loopback 上启动它，以及批准
任何对外效果，都是彼此独立的直接用户操作。

对于外部 MCP 效果，bridge 会先创建一份不发起传输的预览，其中只包含准确请求或
选中文件。随后原生客户端会针对该预览的规范摘要请求一次新的、受保护的用户在场
确认；匹配的预览在交换前只能被原子消费一次。修改请求、目标、用途、协议版本或
会话后，必须重新预览并确认。平台无法提供受保护用户认证时，对外传输保持禁用。

## 管理本地数据

- Skill Hub 只发现智能体本机目录中已经存在的技能，不下载、安装、更新或同步技能包。
  移除选中的本机技能时，会把其准确目录移入系统废纸篓。
- 技能使用次数来自真实的本机调用事件，可按时间窗口查看；浏览技能不计为使用。
- 对话备份写入用户选择的本地目录。启动本地备份任务前，可选择全部对话或准确关键词，
  并先检查预览结果。
- Token 用量视图根据本地记录计算，默认窗口为最近 30 天；也可以选择按智能体、模型或
  工作流统计，并指定自定义时间窗口。工作流视图展示 Graph run、command、准确
  Membership 归属、校验过的数字用量与精确覆盖率。LicoUp 负责工作流用量
  记账，Adaptive Flywheel 负责 route 选择，原生对话位置只作为私有 adapter 绑定。视图不会
  暴露 prompt、reply、tool payload、摘要、压缩或 cache 控件；原生 ledger 只保留活动工作流
  和最新二十份终态汇总。
- 日志和诊断留在本机；用户可以主动保存一份脱敏副本。

不要在公开问题中附加原始日志、历史、本地路径或设备信息。

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
