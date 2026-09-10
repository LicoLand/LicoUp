# LicoUp 当前状态

[English（规范版本）](STATUS.md) · 简体中文（本地化） ·
[文档索引](README.md) · [产品目标](../PRODUCT.zh-CN.md)

本文件是英文 [`STATUS.md`](STATUS.md) 的本地化投影。当前平台与智能体适配
支持明细仍以生成的 [`COMPATIBILITY.zh-CN.md`](COMPATIBILITY.zh-CN.md) 为准。

## 意图

| 范围 | 状态 | 含义 |
| --- | --- | --- |
| 人类—智能体安全会话 | 已批准终局 | 人与醒目可见的智能体共享一套由端点控制的会话体验。 |
| 本机智能体客户端 | 当前第一阶段 | 当前已有证据的产品阶段聚焦本机和明确配置的智能体会话。 |
| 服务商管理的可信历史与历史恢复 | 已批准终局 | 服务商管理的云端历史在获得服务商授权后默认可读；客户端加密必须显式选择，恢复覆盖仍然保留且可用的对象，身份恢复保持独立。 |
| 人类消息、联邦、身份恢复与多设备连续性 | 计划中 | 独立实现并验证前，都只是产品意图。 |
| Lico Arc 端点 Protocol Line | 未来必需边界 | 稳定、线上可观测的 Pairwise Protection、Generic Message、Reliable Exchange、协商与 Transport Profile 属于具名 Lico Arc Protocol Line。当前不支持任何已发布 Protocol Line。 |
| Lico Arc 通讯站外层协议 | 当前候选边界 | Lico Arc Protocol 是唯一的通讯站外层协议；当前 adapter 固定候选 `licoarc.relay.v1` 线路。 |
| 官方网络 | 计划中的便利入口 | 只有取得独立发布与运营证据后才可成为可替换默认入口，且没有任何信任特权。 |

## 实现

| 能力 | 状态 | 当前源码边界 |
| --- | --- | --- |
| 本机智能体发现与会话 | 源码中已实现 | 桌面与原生客户端包含本机和明确配置的智能体适配及会话流程。 |
| 统一 Conversation 后端 | 源码中已实现 | Rust 以一个带索引的 SQLite/WAL 存储作为单聊与群聊、对等 Human/Agent Membership、显式 Assistant 指定、带版本的每 Membership Profile intent、结构化 Event/Part、拓扑中立的不可变 Graph 快照及私有运行时绑定的唯一权威。生成的 Rust/Dart 契约与群聊界面投影同一组封闭事实。`conversation.clear` 清空一个群的 Event 历史、归档未改动的 Continuity 子会话，并插入新的 Assistant Membership 使后续回合从新的原生会话开始；进行中的 turn 或未 finalize 的 Event 会拒绝该写入。 |
| Assistant 工作流与下属智能体 MCP | 源码中已实现 | 四个封闭 Assistant 工具暴露 Profile 排序以及 assistant 临时 workflow 的执行/查看/取消。MCP 绑定的 Agent 必须是活动的指定 Assistant Membership。执行工具在效果前完成本地预检，返回带稳定 stage 与请求 pointer 的有序隐私安全诊断，冻结准确 Membership 绑定与 route receipt；动态失败只返回一次且不隐式重试。直接 `lico_subagent_*` 操作保持独立，持久化 Conversation 宿主是唯一的 run、turn 与 transcript 属主。 |
| Assistant 适配与 target 加载 | 源码中已实现，发布证据未验证 | 群聊“自动适配”通过与一对一相同的 Membership 作用域原生通道寻址指定 Assistant。Adaptive Flywheel 角色与 Assistant model 目录使用一次有界并发的 Rust 选中 target batch。DeepSeek Harness 通过官方 SDK JSON-RPC carrier 打包，且只声明原生协议实际提供的能力；readiness 仍为 unverified。 |
| Gateway Runtime（LLM + Communication Channel） | 源码中已实现 | 单一 `lico-gateway` 进程托管 LLM Gateway 回环层与 Telegram Communication Channel（已配对私聊、`/agent` `/session`、conversation lane）。verified readiness 变更走局部热加载（`gateway inventory reload` / `inventory.sock`：新 ready 准入，绑定/会话保留，不重启进程）。`llm-gateway` CLI 仍为生命周期别名。Channel 仅私聊；发布证据尚未包含对真实 BotFather bot 的验证。 |
| 技能、本机智能体历史、备份与用量 | 源码中已实现 | 当前第一阶段存在相应本机客户端模块。 |
| 可信历史与恢复核心 | 已测试的服务商中立核心 | 核心覆盖服务商授权、无需调用恢复密钥的默认可读历史路径、显式客户端加密选择、全部保留且可用对象的恢复、不可用对象处理、通讯站排除，以及与身份恢复的分离。当前没有云端登录、厂商 adapter、实时同步或 UI 接线。 |
| 完整 Lico Arc 端点 Protocol Line | 未实现 | LicoUp 当前没有可执行的 Lico Arc 自有 Pairwise Protection、Generic Message、Reliable Exchange、协商或 Transport Profile。下方候选外层信封 adapter 不是这条完整端点线路。 |
| 端点保护 | 待直接退役的预览实现 | Secure Client Mesh 当前通过客户端专用 `licomesh.*` 端点 profile 执行配对、认证加密、新鲜性与防重放处理，以及端点认证结果。它不是 Lico Arc Profile，不承诺未来互操作；完整固定 Lico Arc Protocol Line 可用后将直接替换并退役。 |
| Lico Arc 外层信封 | 已实现候选 adapter | 原生核心生成并严格解码封闭的五字段 `licoarc.relay.v1` 信封；加密载体把完整外层路由上下文绑定为认证数据。 |
| 通讯站运输 | 源码中已实现 | 客户端自有 BadTower 运输 adapter 只暴露有界租约、发送、接收与删除操作；其响应只是运输提示。 |
| 退役客户端专用通讯站 API | 已移除 | 不保留原客户端专用通讯站信封/API、`/api/secure-mesh/v1` 路由、服务会话 scope、配置、夹具或兼容面。这里的移除不包括上方仍在使用的 `licomesh.*` 端点预览。 |
| BadTower 候选互操作 | 已在本机验证 | 直接 Lico Arc adapter 已通过实际 BadTower 候选完成两套全新端点场景；这不是产品发布或可信集成。 |
| 官方网络默认值 | 未配置 | 客户端当前没有官方网络默认通讯站入口。 |
| 持续 Assistant | 源码中已实现；真实模型资格仍为 unknown | 普通聊天留在父规范 Conversation。获准的持久工作使用一个子 Conversation，并在创建 Event 序号保留一张父时间线卡片；父卡片执行者徽章不存在。宿主私有的持久采用策略（`offline` → `admitted_shadow` → `qualified_low_risk` → `expanded`）写在既有 continuity schema 中。真实 owner 可通过既有可信 conversation 用例启用或禁用；禁用只阻止新的自动理解/派发，并保留 Goal、历史、在途责任、未知效果和人工恢复。live 证据必须经过已准入的评价会话，并绑定到 owner 准入的带版本语料。宿主生产器遍历该语料，对未标注用例输入调用已绑定的获准 PersistentTurn，用私有期望动作对类型化输出评分，并把收集回执绑定到整条观测。会话与候选 `datasetVersion` 携带数据集 id 和实际语料摘要。语料缺失、为空或版本不匹配时，在任何原生调用之前以类型化错误失败。收集 claim 在第一次原生调用之前转为 Unknown：调用前失败仍为可重试的 NotExecuted；调用后失败保持 Unknown（不能证明尚未执行），重试返回对账。Owner 重新准入新会话以对账；已有证据身份仍阻止二次提交。未绑定运行时保持不可用，hermetic observer 仅用于测试。生产路径不会生成配方分数。重载会重新校验会话、owner、收集回执与撤销。归档或 owner 失效会在同一进程内拒绝下一次自动准入。`expanded` 表示不同合格职责的覆盖，不是原始行数；合成导入不计为 admitted。TestEvidence 不能提升真实模型资格。即使采用默认开启，offline 与 admitted-shadow 也不会自动派发。本机制的源码交付已完成；真实或付费模型资格仍为 unknown。这不是发布声明，也不是手机常驻。 |

源码存在不等于已经验证、发布、支持或正在运营。

## 验证

- 生成的兼容矩阵是当前平台与 adapter 支持投影。
- 可信历史与恢复核心已在服务商中立的测试工具中验证。其默认可读路径不会调用恢复
  密钥。当前没有云端登录、厂商 adapter、实时同步或 UI 接线，因此这些集成没有当前
  验证结论。身份准备与原子提交通过严格的调用方自有合成端口测试；当前未接入
  LicoArc SDK 或运行时身份恢复 adapter。
- 对端加密和移动中转仍为“预览”；矩阵不声明真机、生物识别、硬件密钥保管
  或已发布平台证据。
- 当前 `licomesh.*` 端点证据只验证该预览实现。候选外层信封验收不会把它提升
  为 Lico Arc Profile 或稳定兼容面。
- 当前生成矩阵只为 Codex 启用发送，其余随附 adapter 为未验证；准确行以
  `COMPATIBILITY.zh-CN.md` 为准。
- 一次有界的真实通讯站验收使用两套分别持有客户端状态的全新端点、候选 Lico
  Arc bundle 和实际 BadTower 进程。它验证了受保护命令与认证结果往返、准确
  五字段信封、通讯站可见存储中不存在端点明文、不合规信封被拒绝，以及通讯站
  提示不具权威性。
- 该验收只证明具名本机候选与场景；它不发布 Lico Arc Protocol，不发布
  LicoUp 或 BadTower，不建立平台支持，也不证明托管网络正在运营。

## 发布

| 维度或渠道 | 状态 |
| --- | --- |
| 产品版本元数据 | `0.1.1`（build 2），由 `tools/client-version.json` 拥有 |
| 下一受治理版本 | 当前无计划 |
| 已归档发布历史 | 受治理发布计划中没有归档；`CHANGELOG.md` 记录有 `0.1.1`（2026-08-14）与 `0.1.0-alpha`（2026-07-25）条目；`git tag -l` 只有 `v0.1.0` |
| GitHub Release 发布 | 未声明；不存在 `v0.1.1` 标签 |
| 平台商店发布 | 未声明 |

`0.1.1` 版本元数据与其 CHANGELOG 条目只记录一次版本来源同步，不等于发布。可以构建或
具备 GitHub Release 可选资格，不等于已经发布。逐平台构建、真机验证、GitHub Release
与商店渠道是彼此独立的结论。

## 支持

- 平台与 adapter 支持只限兼容矩阵中的准确生成行。
- “支持”只表示具名当前检查接受该目标，不代表可分发或已上架。
- “预览”表示能力仍在变化，不是稳定互操作声明。
- Lico Arc Station Adapter 与 BadTower 运输是已在本机验证的候选能力，不是
  稳定支持或分发声明。
- 当前 Secure Client Mesh 端点 profile 不承诺未来兼容，也不能替代固定
  Lico Arc Protocol Line 的支持。
- 服务商管理的历史除服务商中立核心外，目前没有云端服务商支持声明。历史恢复不能
  绕过服务商访问控制，也不能重新创建不可用对象，并且不作强制公证或端点证据承诺。
- 当前不声明支持已发布 Lico Arc Protocol 线路、已发布 BadTower 通讯站或
  官方网络。

## 运营

当前没有配置或声明任何正在运营的官方 LicoUp 网络。静态网站、DNS、源码以及
空白或可配置 `stationBaseUrl` 字段都不能证明运营。

## 通讯站运输闭环

当前实现只有一条直接的客户端自有路径：

1. 当前 Secure Client Mesh 预览创建并验证受保护内容；
2. Lico Arc codec 只生成或接受候选五个外层字段；
3. BadTower adapter 只执行有界租约、发送、接收和删除运输操作；
4. 只有端点认证、解密、新鲜性和防重放检查全部成功后，才会删除信封。

退役的客户端专用通讯站表面已在同一次迁移中移除。不存在永久双线路或通讯站翻译网关。
内层 `licomesh.*` 端点预览当前仍然存在并单独等待
直接退役；本文不会把它误报为已经移除。
