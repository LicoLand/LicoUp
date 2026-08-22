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
| 人类消息、联邦、恢复、公证与多设备历史 | 计划中 | 独立实现并验证前，都只是产品意图。 |
| Lico Arc 端点 Protocol Line | 未来必需边界 | 稳定、线上可观测的 Pairwise Protection、Generic Message、Reliable Exchange、协商与 Transport Profile 属于具名 Lico Arc Protocol Line。当前不支持任何已发布 Protocol Line。 |
| Lico Arc 通讯站外层协议 | 当前候选边界 | Lico Arc Protocol 是唯一的通讯站外层协议；当前 adapter 固定候选 `licoarc.relay.v1` 线路。 |
| 官方网络 | 计划中的便利入口 | 只有取得独立发布与运营证据后才可成为可替换默认入口，且没有任何信任特权。 |

## 实现

| 能力 | 状态 | 当前源码边界 |
| --- | --- | --- |
| 本机智能体发现与会话 | 源码中已实现 | 桌面与原生客户端包含本机和明确配置的智能体适配及会话流程。 |
| 统一 Conversation 后端 | 源码中已实现 | Rust 以一个带索引的 SQLite/WAL 存储作为单聊与群聊、对等 Human/Agent Membership、显式 Assistant 指定、带版本的每 Membership Profile intent、结构化 Event/Part、拓扑中立的不可变 Graph 快照及私有运行时绑定的唯一权威。生成的 Rust/Dart 契约与群聊界面投影同一组封闭事实。 |
| Assistant 工作流与下属智能体 MCP | 源码中已实现 | 四个封闭 Assistant 工具暴露 Profile 排序以及 assistant 临时 workflow 的执行/查看/取消。MCP 绑定的 Agent 必须是活动的指定 Assistant Membership。执行工具在效果前完成本地预检，冻结准确 Membership 绑定与隐私安全的 route receipt；动态失败只返回一次且不隐式重试。直接 `lico_subagent_*` 操作要求活动的管理 Membership 并保持独立，持久化 Conversation 宿主是唯一的 run、turn 与 transcript 属主。 |
| Gateway Runtime（LLM + Communication Channel） | 源码中已实现 | 单一 `lico-gateway` 进程托管 LLM Gateway 回环层与 Telegram Communication Channel（已配对私聊、`/agent` `/session`、conversation lane）。verified readiness 变更走局部热加载（`gateway inventory reload` / `inventory.sock`：新 ready 准入，绑定/会话保留，不重启进程）。`llm-gateway` CLI 仍为生命周期别名。Channel 仅私聊；发布证据尚未包含对真实 BotFather bot 的验证。 |
| 技能、历史、备份与用量 | 源码中已实现 | 当前第一阶段存在相应本机客户端模块。 |
| 完整 Lico Arc 端点 Protocol Line | 未实现 | LicoUp 当前没有可执行的 Lico Arc 自有 Pairwise Protection、Generic Message、Reliable Exchange、协商或 Transport Profile。下方候选外层信封 adapter 不是这条完整端点线路。 |
| 端点保护 | 待直接退役的预览实现 | Secure Client Mesh 当前通过客户端专用 `licomesh.*` 端点 profile 执行配对、认证加密、新鲜性与防重放处理，以及端点认证结果。它不是 Lico Arc Profile，不承诺未来互操作；完整固定 Lico Arc Protocol Line 可用后将直接替换并退役。 |
| Lico Arc 外层信封 | 已实现候选 adapter | 原生核心生成并严格解码封闭的五字段 `licoarc.relay.v1` 信封；加密载体把完整外层路由上下文绑定为认证数据。 |
| 通讯站运输 | 源码中已实现 | 客户端自有 BadTower 运输 adapter 只暴露有界租约、发送、接收与删除操作；其响应只是运输提示。 |
| 退役客户端专用通讯站 API | 已移除 | 不保留原客户端专用通讯站信封/API、`/api/secure-mesh/v1` 路由、服务会话 scope、配置、夹具或兼容面。这里的移除不包括上方仍在使用的 `licomesh.*` 端点预览。 |
| BadTower 候选互操作 | 已在本机验证 | 直接 Lico Arc adapter 已通过实际 BadTower 候选完成两套全新端点场景；这不是产品发布或可信集成。 |
| 官方网络默认值 | 未配置 | 客户端当前没有官方网络默认通讯站入口。 |

源码存在不等于已经验证、发布、支持或正在运营。

## 验证

- 生成的兼容矩阵是当前平台与 adapter 支持投影。
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
| 产品版本元数据 | `0.1.0-alpha` |
| 下一受治理版本 | 当前无计划 |
| 已归档发布历史 | 无 |
| GitHub Release 发布 | 未声明 |
| 平台商店发布 | 未声明 |

可以构建或具备 GitHub Release 可选资格，不等于已经发布。逐平台构建、真机
验证、GitHub Release 与商店渠道是彼此独立的结论。

## 支持

- 平台与 adapter 支持只限兼容矩阵中的准确生成行。
- “支持”只表示具名当前检查接受该目标，不代表可分发或已上架。
- “预览”表示能力仍在变化，不是稳定互操作声明。
- Lico Arc Station Adapter 与 BadTower 运输是已在本机验证的候选能力，不是
  稳定支持或分发声明。
- 当前 Secure Client Mesh 端点 profile 不承诺未来兼容，也不能替代固定
  Lico Arc Protocol Line 的支持。
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
