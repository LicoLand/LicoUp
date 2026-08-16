# LicoUp 架构

[English（规范版本）](README.md) · 简体中文（本地化） · [文档索引](../README.md) · [项目首页](../../README.zh-CN.md)

长期产品目标与边界由[产品定义](../../PRODUCT.zh-CN.md)负责，当前状态由
[状态文档](../STATUS.zh-CN.md)负责。当前组件和依赖事实由 Rust/Flutter 模块树、
`apps/desktop/packaging.modules.json` 以及
`apps/desktop/scripts/client-architecture/` 下的架构验证器负责。本文件是这些来源的
公开架构投影。

LicoUp 是一个本地优先的客户端。Flutter 负责界面，Rust 负责原生客户端核心、
本机及可访问虚拟机适配器、有界任务和[当前正在退役的端点保护预览](../STATUS.zh-CN.md)
实现。稳定端点线路语义由 Lico Arc Protocol 而不是本客户端仓库负责。

## 设计理念

- **多元** — 通过适配器连接不同智能体和设备。
- **互联** — 让本机工具与对端客户端使用清晰的连接流程。
- **开放** — 源代码和客户端契约都可以检查和扩展。
- **融合** — 用统一应用层隔离界面与具体适配器。

## 组件

```mermaid
flowchart TB
    UI["Flutter 界面"] --> APP["应用层"]
    APP --> CORE["Rust 原生客户端核心"]
    CORE --> CONVERSATIONS["统一 Conversation 领域<br/>Membership · Event · Role"]
    CORE --> STRATEGIES["Adaptive Flywheel 策略领域<br/>不可变 Graph · 持久化运行"]
    CONVERSATIONS --> STORE["带索引的 SQLite/WAL 客户端状态"]
    CORE --> AGENTS["智能体适配器<br/>ACP · app-server · RPC · CLI"]
    AGENTS --> VM["可访问的用户自有虚拟机<br/>OrbStack 发现 · OpenSSH stdio · ACP/Hermes Gateway"]
    CORE --> MESH["正在退役的端点保护预览<br/>当前执行器"]
    MESH --> ARC["Lico Arc 候选 adapter<br/>封闭五字段信封"]
    ARC --> STATION["兼容通讯站<br/>不可信运输"]
    STATION --> PEER["对端 LicoUp 客户端"]
    KEYS["平台安全存储<br/>用户确认"] --> MESH
    LINE["固定 Lico Arc Protocol Line<br/>未来必需的端点线路权威"] -. "治理合规执行" .-> MESH
```

| 区域 | 职责 |
| --- | --- |
| Flutter 界面 | 导航、视图、用户选择和安全摘要 |
| 应用层 | 客户端流程和与适配器无关的规则 |
| Rust 原生核心 | 本地任务、协议、校验和加密 |
| Conversation 领域 | 单聊/群聊、Human/Agent Membership、结构化 Event 与角色的唯一持久化权威；原生运行时位置保持私有 |
| Adaptive Flywheel 策略领域 | 独立于 Conversation 历史的不可变包版本、JSON Graph 校验、绑定、准确授权、持久化运行归约与有界效果调度 |
| 智能体适配器 | 转换受支持的本机接口及自动发现或明确配置的 OpenClaw/Hermes 虚拟机协议连接 |
| 平台桥接 | 安全存储、用户确认和平台启动 |
| 端点保护预览 | 当前 LicoUp 执行器、本地密钥/Provider 保管、对端信任、审批和正在退役的端点实现；它不是稳定协议权威 |
| Lico Arc Protocol Line | 拥有线上可观测的 Pairwise Protection、Generic Message、Reliable Exchange、协商与 Transport Profile 语义 |
| Lico Arc adapter | 严格候选外层信封 codec 与四项有界通讯站运输操作 |

## 内置能力边界

默认客户端只包含下表中的基础能力和本地优先场景。每一行都有窄接口和专属回归模块；
任何一个场景都不能直接访问另一个场景的存储或界面。

| 能力 | 独立职责 |
| --- | --- |
| Rust 任务队列 | 本机任务的有界多生产者 FIFO、背压、断开处理和工作线程生命周期 |
| ACP 适配 | 智能体会话协商、原生继续对话、会话列出/加载、事件流、权限等待、取消和脱敏错误 |
| MCP 适配 | 有界 MCP/JSON-RPC 校验、请求 ID 保持、响应转发，以及外部动作的一次性审批 |
| 智能体发现 | 只并发探测 Agent 扫描路径清单中的命名二进制、配置和历史目录。不遍历 PATH、个人资料库根、照片/音乐库或网络宗卷。未使用智能体的发现和冷启动不会执行第三方 Agent 二进制。家目录只从环境变量读取；macOS firmlink 等价路径按同一规则分类。未使用智能体的探测对其他 App 容器只做词法分类，不去 stat。Token 用量在打开监测页之前不会扫描 |
| 适配插件管理 | 用一个原生目录管理随附原生通道、随附 ACP 通道和明确可安装的 LicoUp 桥接；生命周期操作需要确认且只能修改 LicoUp 自有状态 |
| 智能体对话 | 单聊与群聊共用统一 Conversation 模型；Human 与 Agent Principal 通过显式 Membership 参与。每个客户端数据根只有一个通过私有本机 IPC 服务的 CLI 宿主，它独立于 GUI 生命周期拥有所有打包适配器已接受的轮次。新建与原生续接会话在该宿主中保留进程内、可唤醒的进度；活动轮次在支持时使用原生 steer，否则在准确会话的安全边界继续。可替换观察者使用 Conversation 作用域句柄和进程内游标重新附着；低于每个活动轮次 16 MiB 可丢弃缓存下界的内容从已提交 Conversation Event 准确重放。观察者断开不等于取消或 steer。原生会话是适配器拥有、私下绑定到 Membership 的执行细节。本地[下属智能体 MCP](../protocols/subagent-mcp.zh-CN.md)只按 `conversationId + membershipId` 调度，不暴露原生续接路径 |
| 适应性飞轮 | 目录在 ZIP 导入之前保持为空。导入 ZIP 在根目录包含 `workflow.json`，并可带 `scripts/`；Graph 决定流水线或 Agent Loop。不可变版本拥有绑定与准确授权，持久化运行提供有界就绪前沿调度以及明确终态和恢复状态。不存在 Better Plan 安装动作，也不存在序号式 Conversation 兼容路径 |
| 技能管理 | 只读发现本机已有技能、可恢复地移入系统废纸篓，并按时间窗口统计真实调用次数；不提供下载、安装、更新或同步通道 |
| 对话管理 | 带索引的列表、精确读取、Event 分页与检索，以及有界的统一导入/导出；绝不改写第三方原生历史 |
| Delivery Plan | 持久化 Plan 与 Checkpoints 是交付资格和推进的权威。Conversation runtime 以稳定顺序领取完整 eligible frontier，通过有界原生通道派发，并且只在终态结算后推进 checkpoint。Adaptive Flywheel 仍是唯一的 Agent/model route 选择权威 |
| 用量统计 | 依据本机记录按智能体或模型聚合 Token；包含不可变历史日/模型汇总、当日事件明细、无路径 Plan/Task/dispatch 汇总和精确覆盖率，使用 90 天扫描缓存，默认展示 30 天并支持 7/30/90 天窗口 |
| 端点保护预览 | 当前配对、信任、对端消息/文件加密、防重放、端点认证结果与 Lico Arc 候选承载；该退役中实现不承诺未来兼容 |

默认启动和
导航不会加载可选协作。客户端必须通过独立操作导入可信签名公钥；该操作本身
不能建立信任。显式启动前，客户端还会重新校验不可变的软件包来源以及固定、
已签名且只监听 loopback 的外部运行器。

交付视图只消费一个安全的原生 ledger 投影。LicoUp 负责 Plan 调度与 checkpoint 推进，
Adaptive Flywheel 负责 route 选择，Conversation Membership 负责 Agent dispatch。原生续接
位置只作为私有适配器绑定。投影只保留安全 code、本地化角色与状态标签、Agent/model
标签、数字 Token 计数、精确或估算覆盖率和 Plan 层级；明确排除 prompt、reply、tool
payload、摘要、压缩、cache 控件以及第二套客户端 context 模型。保留范围限定为活动交付
和最新二十份终态汇总。

当前智能体与平台适配目标由[兼容性文档](../COMPATIBILITY.zh-CN.md)生成。
通讯站线路与运营状态由[状态文档](../STATUS.zh-CN.md)记录。

## 虚拟机发现与原生协议边界

对于 OpenClaw 和 Hermes，桌面客户端通过有界命令枚举本机正在运行的 OrbStack
虚拟机，并检查固定的官方及常见可执行文件位置；它不会读取虚拟机配置或历史。Rust
会先校验虚拟机名和返回的绝对路径，再创建临时的 `machine@orb` 路由；自动发现的
虚拟机路由不会进入发现缓存。扫描具有固定的时间、输出、虚拟机数量和并发上限。

对于其他虚拟机，Flutter 收集主机名、可选端口/用户、虚拟机内程序以及绝对工作目录；
Rust 校验封闭的连接结构，只把它保存在权威手动目标中。密码、私钥、命令片段、相对
虚拟机目录和未知字段都会被拒绝。

原生核心以 batch 模式启动平台系统 `ssh`，强制主机密钥校验，关闭 TTY、转发、本地
命令、环境转发和连接复用。它只传入一条经过 shell 引号保护的固定虚拟机命令。
OpenClaw 启动 ACP；Hermes 在可选 ACP 包通过固定能力检查时启动 ACP，否则自动发现
会用安装器虚拟环境的 Python 启动 `tui_gateway.entry`。两种协议都通过 stdin/stdout
交换有界 JSON-RPC。本机协作 MCP 描述不会发送到虚拟机。会话发现和回读使用所选协议
的会话列出/加载操作；客户端不会扫描、挂载或复制虚拟机历史存储。选中该目标时，
界面会持续显示 SSH 目标。

## 平台适配边界

共享 Rust 和 Flutter 层保持平台无关。各原生宿主只负责不能移植的平台动作：

| 平台 | 原生适配器职责 |
| --- | --- |
| macOS | 应用发现、Keychain/用户在场桥接、打包和启动 |
| Windows | 应用发现、Credential Manager 密钥保管、客户端授权会话、打包和启动 |
| Ubuntu | 软件包/应用发现、Secret Service 或明确的仅内存密钥保管、打包和启动 |
| Android | 软件包发现、Keystore/BiometricPrompt 桥接、Rust FFI 生命周期、安装和启动 |
| iOS | 应用容器集成、Keychain/LocalAuthentication 桥接、Rust FFI 生命周期、安装和启动 |

源码适配、普通构建、真机安全证据、GitHub Release 制品和应用商店发布是彼此独立的
结论。当前[兼容性状态](../COMPATIBILITY.zh-CN.md)分别记录这些结论，绝不把
模拟器或源码检查提升成真机或发布证明。
调用方参数和普通状态文件都不能证明用户已经批准；受保护操作必须使用平台持有的
授权会话。

对于外部 MCP 效果，bridge 可以暂存准确预览，但不能执行交换或批准该预览。
原生命令随后针对规范
摘要请求一次新的平台用户在场确认，并在交换前原子消费匹配的短期预览，且只能
消费一次。

## 当前正在退役的端点保护预览分层

当前正在退役的端点保护预览使用一个固定安全配置。本节只是该预览的实现清单，
不定义 Lico Arc Profile，也不承诺未来线路兼容。完整固定 Lico Arc Protocol
Line 替换它时，该预览将直接退役而不会保留兼容模式。当前每种算法只负责一个
明确任务，安全性不以开启的算法数量衡量。

```mermaid
flowchart TB
    ID["对端身份<br/>Ed25519 签名"] --> SETUP["会话建钥<br/>X25519 + ML-KEM-1024"]
    SETUP --> DERIVE["密钥派生与棘轮<br/>HKDF-SHA256"]
    DERIVE --> CONTENT["消息保护<br/>ChaCha20-Poly1305"]
    CONTENT --> VERIFY["先校验再使用<br/>不回退明文"]
```

只有当不同算法承担不同职责，并且组合规则已经过检查时，协议才会组合它们。签名握手会
固定本次会话使用的安全配置。派生密钥有清晰标签，不能把一个任务的密钥复用于另一个
任务。任何安全检查缺失或失败，都不能开启明文通信。

## 当前平台密钥保管

当前客户端会先检查平台能力，再选择本机密钥存储。系统安全存储可用时使用系统存储，
否则明确使用内存临时存储。内存密钥会在重启后丢失，因此客户端需要重新配对并创建新密钥。
存储失败不会开启明文通信。

当前平台适配器保护密封后的秘密数据。客户端还没有通用的外部加密提供者接口。
客户端没有运行时加密补丁加载器。

把同一份密封密钥数据移动到另一种本机存储，不会改变选中的线上 profile。私钥保管与
本地 Provider 选择仍由 LicoUp 负责；线上可观测的 profile 与协商规则属于固定的
Lico Arc Protocol Line。当前存储接口仍可以把密钥数据返回原生核心，因此不能把系统
存储直接描述成所有协议密钥都由硬件保护或不可导出的证明。平台支持声明必须有当前
测量证据。

## 数据边界

```mermaid
sequenceDiagram
    participant A as 客户端 A
    participant R as 兼容且不可信的通讯站
    participant B as 客户端 B
    A->>A: 用户选择 B 并批准一次内容
    A->>A: 为 B 加密
    A->>R: 五字段 Lico Arc 信封
    R->>B: 转发不透明受保护载体
    B->>B: 认证、检查新鲜性/重放并解密
```

中转边界只是运输适配，不是客户端与服务端之间的信任关系。当前预览只与对端
端点配对并协商；稳定实现则必须执行一条固定 Lico Arc Protocol Line 的
Pairwise Protection 与协商语义。选择中转地址或使用它的投递接口，不代表
LicoUp 与中转端配对，不会使中转端成为身份权威，也不会把任何安全决策委托给它。

Lico Arc Protocol 拥有线上可观测的 Pairwise Protection、Generic Message、
Reliable Exchange、协商与 Transport Profile 契约。LicoUp 拥有它们的本地执行、
私钥、Provider 配置、明文、历史、备份、用户信任、审批和本地效果。当前正在
退役的端点保护预览不是 Lico Arc Profile，也不会保留为未来兼容面。

当前客户端自有 adapter 固定候选 `licoarc.relay.v1` 外层契约。公开对象准确
包含 `contractVersion`、`envelopeId`、`mailboxId`、`ciphertext` 和
`expiresAt`；客户端拒绝未知字段与不受支持版本。加密载体把这些路由字段绑定为
认证数据，并把私有头与受保护内容保留在密文字段内。

BadTower HTTP adapter 只有四项运输操作：租约一个 mailbox、发送一个信封、
接收有界信封集合以及删除一个信封。该 adapter 是 LicoUp 自有实现边界，不是
通讯站 SDK、协议权威或可信产品集成。一次有界本机验收已经用两套全新初始化
端点，通过实际 BadTower 候选验证这条路径。准确验证与发布边界见
[状态文档](../STATUS.zh-CN.md)。

客户端把中转端的所有输出都视为攻击者可控输入。LicoUp 从不接受来自中转端
的加密算法、密钥、信任根或安全策略。中转端报告的投递回执、租约、时间和
队列状态都只是运输提示，不能证明对端身份、数据包新鲜性、未被重放、完整性
或最终接收。LicoUp 依据端点持有的端到端状态作出这些判断；只有对端认证的
协议状态能够支持最终接收结论时，客户端才接受最终回执。

客户端遵守以下规则：

- 本地路径、日志、历史、用量记录、凭据和原始运行时数据留在设备上。
- 默认客户端场景不会把敏感运行时数据或用户内容明文发送给服务端。
- 可选的外部 MCP 请求只能包含受保护一次性确认中展示的准确正文和文件。HTTPS 保护传输，
  但指定的外部服务可以读取用户批准的内容。
- 如果没有针对外部服务的准确确认，受保护内容离开客户端时必须是密文，并发给指定的
  对端客户端，除非你选择了 Telegram 等外部通讯软件作为你的可信通道。
- 发送端先加密，再进行网络传输；接收端先认证、校验，再使用内容。
- 通讯站不在可信客户端边界内。客户端安全不依赖通讯站的存储策略或运营承诺。
- 只有密文和最少路由字段可以跨越通讯站边界。私钥、本地信任与审批策略、协议定义的
  新鲜性和防重放状态，以及经过认证的最终回执状态仍由端点持有。
- 密钥保存在可用的系统安全存储中，或明确使用仅内存存储。平台支持时，使用受保护密钥需要用户确认。
- 日志和测试报告只保留安全摘要，不保存原始用户内容。

## 仓库结构

| 路径 | 用途 |
| --- | --- |
| `apps/desktop/` | Flutter 桌面与移动客户端 |
| `crates/licoup-native/` | Rust 客户端核心和命令 |
| `packages/contracts/client/` | 客户端自有 Schema |
| `tests/` | 使用合成数据的契约和边界测试 |
| `tools/` | 可复用的构建与验证工具 |

计划、临时脚本、本地技能、原始证据和运行时数据属于本地工作材料，不进入公开源码。
