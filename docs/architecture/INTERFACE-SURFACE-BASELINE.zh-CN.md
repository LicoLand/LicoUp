# 接口表面基线

[架构](README.zh-CN.md) · [English (normative)](INTERFACE-SURFACE-BASELINE.md)

本文冻结 CLI/MCP 重构（[#285](https://github.com/LicoLand/LicoUp/issues/285) 及其子任务）必须保持不变的接口表面。它记录当前存在什么、每份契约归谁所有、以及每个任务独占哪些路径。本文不含设计提案：每一行都取自下方所述版本的真实代码。

基线版本：**`8638e1040ac7abfa4005673a9fdac05065b3f5cc`**（`nightly`）。核对下文任何断言时请钉住该提交；后续 `nightly` 可能已前进。智能体数量、工具目录与二进制名称，均为契约测试已经钉住的值。

**路径约定。** 以 `crates/`、`apps/`、`tests/`、`tools/`、`schemas/` 或 `docs/` 开头的路径为仓库相对路径。其余路径相对于 `crates/licoup-native/src/`，例如 `domain/subagent_mcp/mod.rs` 即 `crates/licoup-native/src/domain/subagent_mcp/mod.rs`。表格中的裸 `:NNN` 行号继承该行所写的文件；若该行未写文件，则继承同一表格中最近的前一行。所有引用均按这些规则解析。

## 1. 命令表面

### 1.1 CLI 接受什么

权威的 argv 表面是命令注册表，不是帮助文本。

| 项 | 归属 | 数量 / 值 |
| --- | --- | --- |
| 已注册命令路径 | `crates/licoup-native/src/ffi/commands/mod.rs:893`（`build_command_table`） | **162** |
| 动态通道：`licoup rpc stdio` | `crates/licoup-native/src/bin/licoup.rs:39-52` | NDJSON RPC |
| 动态通道：`licoup rpc conversation` | `crates/licoup-native/src/bin/licoup.rs:54-58` | stdio↔socket 代理 |
| 动态通道：`licoup rpc conversation-host` | `crates/licoup-native/src/bin/licoup.rs:60-64` | 常驻宿主 |
| 其余全部 | `crates/licoup-native/src/bin/licoup.rs:66-71` | `execute_cli(argv)` |

`crates/licoup-native/src/bin/licoup/presentation.rs` 只负责打印用法。它漏列了若干命令族，**不是**契约；不要从它推导基线。

### 1.2 准入

| 关注点 | 位置 | 必须保持的行为 |
| --- | --- | --- |
| 注册表类型 | `ffi/commands/mod.rs:276-422` | `CommandSpec` → `CommandDef` → `CommandTable` |
| 准入 | `ffi/commands/mod.rs:354-421` | 先精确匹配位置参数前缀，再校验基数，最后解析选项 |
| 参数上限 | `ffi/commands/mod.rs:532-554` | ≤4096 个参数、单参数 ≤2 MiB、`help` 必须独立出现 |
| 选项 | `ffi/commands/mod.rs:556-677` | 布尔与取值两种元数、可重复、必填 |
| 约束 | `ffi/commands/mod.rs:679-721` | `AtLeastOne`、`MutuallyExclusive`、`OneOf`、`ConditionalRequired` |
| 处理函数入参 | `ffi/commands/mod.rs:779-801`（`admitted_params`） | 仅插入存在的键；标志位转为 `Bool(true)` |
| 错误形状 | `ffi/commands/mod.rs:188-260`（`CliCommandError`） | `code` / `stage` / `component` / `retryable` / `recovery` |

准入错误码是已发布契约，共 **13** 个；契约测试套件逐一断言
（`crates/licoup-native/tests/cli_command_contract_cases.rs:61-110`）。

| 错误码 | 触发条件 |
| --- | --- |
| `cli_command_missing` | 没有任何已注册路径匹配 |
| `cli_command_unknown` | 路径前缀已知，但命令不完整 |
| `cli_operation_unsupported` | 该路径未注册此 operation |
| `cli_required_argument_missing` | 未提供必需的定位参数 |
| `cli_required_option_missing` | 未提供必需选项 |
| `cli_argument_unexpected` | 在 `Cardinality::Exact` 下出现了多余 token |
| `cli_option_unknown` | 选项不在 spec 中 |
| `cli_option_duplicate` | 不可重复的选项被给了两次 |
| `cli_option_value_missing` | 取值型选项缺少取值 |
| `cli_option_constraint_violation` | `AtLeastOne` / `MutuallyExclusive` / `OneOf` / `ConditionalRequired` 约束未满足 |
| `cli_argument_count_exceeded` | 参数超过 4096 个 |
| `cli_argument_bytes_exceeded` | 单个参数超过 2 MiB |
| `cli_json_invalid` | JSON 参数解析失败 |

命令处理模块（一文件一模块，声明于 `ffi/commands/mod.rs:8-28`）：
`adapter`、`agent_conversation`、`agent_hub`、`agent_usage`、`autostart`、
`client_conversation`、`client_update`、`collaboration`、`gateway`、
`llm_gateway`、`mcp`、`mobile`、`opencode_serve`、`provider_quota`、
`resource_usage`、`secure_mesh`、`skill`、`snapshots`、`state`、`strategy`、
`targets`。

### 1.3 RPC 协议

| 项 | 值 | 位置 |
| --- | --- | --- |
| 协议字符串 | `licoup.stdio.v1` | `bin/licoup.rs:29`；契约副本在 `contracts/conversation_protocol.rs:5` |
| 方法数 | **29** | `contracts/conversation_protocol.rs:14-44` |
| 帧上限 | 16 MiB | `contracts/conversation_protocol.rs:6-9` |
| 分帧方式 | 换行分隔 | `contracts/frame.rs:16` |
| 解析器 | `parse_stdio_rpc_request` | `bin/licoup/stdio_rpc/request.rs:13-170` |
| 分发 | `serve_stdio_rpc_inner` | `bin/licoup/stdio_rpc/server.rs:66-608` |

29 个线上方法收敛为 8 个分发变体（`bin/licoup/stdio_rpc/model.rs:11-43`）：
`Execute`、`Conversation{operation}`、`ClientConversation`、
`StrategyExecute`、`Catalog{operation}`、`StateGet`、`StateSet`、`Shutdown`。

信封形状（归属：`bin/licoup/stdio_rpc/response.rs`）：

| 种类 | 字段 | 位置 |
| --- | --- | --- |
| 成功 | `protocol`、`id`、`workflowId`、`ok: true`、`result` | `:184-203` |
| 错误 | `protocol`、`id`、`workflowId`、`ok: false`、`error: ClientError` | `:205-223` |
| 流式事件 | `protocol`、`id`、`workflowId`、`kind: "event"`、`sequence`、`event` | `:60-103` |
| 流式终止 | `protocol`、`id`、`workflowId`、`kind: "terminal"`、`sequence`、`ok`、`result`/`error` | `:105-167` |

`ClientError` 字段为 `code`、`stage`、`component`、`retryable`、`recovery`、
`presentationArgs`（`ffi/generated/client_error.rs:159-172`）。`code` 枚举共
**45** 个值（`:6-97`）。

### 1.4 二进制

`crates/licoup-native/Cargo.toml:107-134` 构建 7 个二进制。其中 5 个会打包，
1 个是内嵌副本，1 个仅供测试。

| 二进制 | 角色 | 打包方式 |
| --- | --- | --- |
| `licoup-cli` | 全部 CLI 表面 | sidecar，另有 Xcode 内嵌 |
| `lico-subagent-mcp` | Subagent MCP connector | sidecar **并**内嵌进 Codex 插件 |
| `lico-conversation-mcp` | Conversation MCP 服务 | sidecar |
| `lico-gateway` | gateway 运行时 | sidecar |
| `lico-llm-gateway` | 旧 gateway 别名 | 仅 Xcode 内嵌，不在 `packaging.modules.json` 中 |
| `lico-agent` | agent sidecar | sidecar |
| `lico-secure-mesh-kt-mock` | 仅验收测试 | 不打包（受 feature 门控） |

## 2. MCP 工具目录

两个服务、一个共享引擎（`core/mcp`）。重构必须让两侧的目录、身份三元组与
错误投影保持逐字节一致。

| | Subagent | Conversation |
| --- | --- | --- |
| 二进制 | `lico-subagent-mcp` | `lico-conversation-mcp` |
| `SERVER_NAME` | `lico-up-subagents` | `lico-up-conversations` |
| `SERVER_VERSION` | `0.12.0` | `0.1.0` |
| `PROTOCOL_REVISION` | `2025-06-18` | `2025-06-18` |
| 兼容修订 | `["2025-11-25"]` | 无 |
| 工具数 | **10** | **5** |
| 传输 | stdio connector → 桌面托管的回环 HTTP `/mcp` | 仅 stdio |
| 目录顺序 | `domain/subagent_mcp/mod.rs:42-53`（`TOOL_NAMES`） | `bin/lico-conversation-mcp.rs:133-174` |
| 目录构造（schema、`required`） | `domain/subagent_mcp/mod.rs:736-808` | `bin/lico-conversation-mcp.rs:133-174` |

**对任务清单的更正：** Issue #289 写的是"现有 9 + 5 工具目录"。今天核实到的
数量是 **10 + 5**；第 10 个 subagent 工具是 `lico_assistant_workflow_policy`。
任何一致性测试都必须以下文数量为准，而不是 issue 文本。

Subagent 工具（按序）：`lico_assistant_profiles`、
`lico_assistant_workflow_execute`、`lico_assistant_workflow_inspect`、
`lico_assistant_workflow_cancel`、`lico_subagents_list`、`lico_subagent_probe`、
`lico_subagent_delegate`、`lico_subagent_continue`、`lico_subagent_cancel`、
`lico_assistant_workflow_policy`。

Conversation 工具（按序）：`lico_conversation_list`、`lico_conversation_get`、
`lico_conversation_search`、`lico_conversation_export`、`lico_conversation_import`。

### 2.1 Schema 与校验

输入 schema 是 JSON Schema 字面量，且 `additionalProperties: false`
（subagent：`domain/subagent_mcp/mod.rs:869-884`；conversation：
`bin/lico-conversation-mcp.rs:176-187`）。校验在业务逻辑之前于引擎内执行
（`core/mcp/server.rs:298-308`）：未知工具名返回 `-32601`，非法入参返回
`-32602`。

### 2.2 错误投影

应用失败以**成功的** JSON-RPC 结果返回，携带 `isError: true` 与该主体
（归属：`core/mcp/server.rs:323-337`）：

`schemaVersion: "licoup.mcp.error.v1"`、`reasonCode`、`stage`、`retryable`、
`recovery`。

注意字段名是 `reasonCode`，不是 `code`。引擎级 JSON-RPC `error` 信封是另一
套（`core/mcp/wire.rs:45-56`），使用标准码 `-32600`、`-32601`、`-32602`、
`-32002`、`-32700`、`-32800`。

原生→MCP 投影的归属方，必须与 store 的错误字符串保持一致：

| 投影 | 位置 |
| --- | --- |
| 适配器失败 | `domain/subagent_mcp/mod.rs:650-663` |
| 宿主失败 | `domain/subagent_mcp/production.rs:429-468` |
| stdio 服务宿主错误 | `bin/licoup/stdio_rpc/server/client_conversation.rs:81-99` |
| 宿主客户端错误 | `platform/subagent_mcp_host_client.rs:128-154` |
| store 准入错误 | `crates/licoup-conversation/src/store/dispatches.rs:69-163` |

### 2.3 回执与信封的 schema 版本

| Schema 字符串 | 使用者 | 位置 |
| --- | --- | --- |
| `licoup.subagent.receipt.v3` | delegate / continue / cancel 回执 | `domain/subagent_mcp/mod.rs:621-648` |
| `licoup.subagents.v3` | `lico_subagents_list` | `domain/subagent_mcp/production.rs:390` |
| `licoup.subagent.readiness.v2` | `lico_subagent_probe` | `domain/subagent_mcp/mod.rs:429` |

claim 状态字符串（上线并入库）：
`claimed`、`running`、`cancel-requested`、`reconciliation-required`、
`completed`、`failed`、`cancelled`
（`crates/licoup-conversation/src/client_conversation/mod.rs:445-457`）。

### 2.4 传输不变量

subagent 服务只绑定回环，要求精确的数字 `Host`、不得有 `Origin`，并要求每个
被接纳 caller 各自持有 bearer token（`platform/subagent_mcp_supervisor.rs:500-544`）。
token 集合即适配器注册表的 caller 集，因此已发布的 token 映射**就是**成员集。
上限：32 连接、64 session、8 工具 worker
（`platform/subagent_mcp_supervisor.rs:26-28`）。

## 3. 身份语义

存在两种 actor，且是刻意区分的。重构必须两者都保留。

| | 本地管理员 actor | 成员 actor |
| --- | --- | --- |
| 入口 | 进程内 CLI / 桌面 | MCP 工具调用 |
| 身份来源 | 调用方提供的 `authorMembershipId` / `ownerMembershipId` | 回环服务认证后的 `CallerContext` |
| 校验 | 仅 owner 类操作走 `ensure_local_owner` | `effect_scope` + `verify_caller` + `verified_assistant` |
| 绑定检查 | owner + active + human | active + agent + `agent_id == provider_id` + 同一会话 |

代码中**不存在** `local-admin` 枚举变体；这一区分是行为性的，由各入口实际执行
哪些闸门决定。

| 闸门 | 位置 |
| --- | --- |
| 本地 owner | `crates/licoup-conversation/src/store/mod.rs:5561-5580` |
| subagent caller 与 target 成员资格 | `crates/licoup-conversation/src/store/dispatches.rs:69-86` |
| Assistant 资格 | `crates/licoup-conversation/src/store/mod.rs:1931-1944` |
| MCP caller 绑定 | `domain/subagent_mcp/production.rs:44-64` |
| MCP assistant 绑定 | `domain/subagent_mcp/production.rs:66-92` |
| 一次性注册批准 | `crates/licoup-agent-runtime/src/lib.rs:408-455` |
| 消息作者绑定 | `domain/client_conversation/service.rs:553-573` —— **不校验**；CLI 路径按设计信任传入的作者 id |

最后一行是要保留的不对称性：普通发帖时 CLI 路径信任传入的作者 id，而 MCP 路径
额外要求一个已认证且绑定到该会话的 agent 成员资格。

## 4. 常驻 Conversation 宿主

| 项 | 值 | 位置 |
| --- | --- | --- |
| endpoint 名 | `licoup-conversation-{token}-{generation}` | `platform/conversation_host_transport.rs:89-100` |
| token 文件 | `<root>/client-state/conversation-runtime/endpoint-token` | `:105-115` |
| token 形式 | 32 位小写十六进制，`create_new` + 同步 + 加固 | `:119-138` |
| generation | 可执行文件元数据的 SHA-256，取前 8 字节 → 16 位十六进制 | `:19-67` |
| 宿主记录 | `generation\nhost_pid\n[client_pid]` | `bin/licoup/conversation_host.rs:39-101` |
| 属主环境变量 | `LICOUP_CLIENT_PID` | `:32-37` |
| 常量 | 80 次连接尝试、25 ms 重试、2 s 陈旧等待、500 ms 属主检查、300 s 空闲宽限 | `:32-37` |
| 属主死亡退出 | checkpoint 后跳出 accept 循环 | `:497-503` |
| 空闲退出（无属主） | 宽限期后、且 attendance 空闲时才退出 | `:504-514` |

该通道的认证方式是**持有 socket 名**，而读取该名字需要私有 token 文件。线上不
传输任何调用方身份。

### 4.1 当前的退出行为

| 入口 | 行为 |
| --- | --- |
| GUI 死亡 | 宿主在 500 ms 内察觉，checkpoint 后退出；进行中的 turn 线程随进程终止 |
| stdio 通道管道关闭 | 该通道会 join 直到每个 Agent turn 到达终态（`bin/licoup/stdio_rpc/server.rs:92-99`） |
| 代理通道 | stdout 消失后继续读干宿主，便于桌面重连（`bin/licoup/conversation_host.rs:282-313`） |
| attendance worker | 属主退出时被 detach，永不等待（`:443-449`） |

### 4.2 当前的更新行为

| 步骤 | 位置 |
| --- | --- |
| apply 脚本退出 GUI 并等待其 pid 消失 | `domain/client_update/native_runner/script.rs:93-148` |
| 预写 `pending` 交接文件 | `domain/client_state_migration.rs:414-484` |
| 候选版本在状态准入前先 claim | `:371-403`，由 `:178-186` 调用 |
| endpoint generation 阻止新二进制附着旧宿主 | `platform/conversation_host_transport.rs:44-48, 89-100` |

### 4.3 交接验证地图

重构必须覆盖的每个阶段与故障，都已有代码位置和至少一个测试。请覆盖这些，而
不是另造抽象。

| 阶段 / 故障 | 代码 | 现有测试 |
| --- | --- | --- |
| 从桌面通道启动宿主 | `bin/licoup/conversation_host.rs:255-280` | `native-client-smoke`、`subagent_mcp_startup` |
| 意外退出后重启宿主 | supervisor | `platform/subagent_mcp_supervisor.rs:1595-1638` |
| 工作进行中属主死亡 | `bin/licoup/conversation_host.rs:497-503` | `:787-951` |
| 空闲退出 | `:504-514` | `:531-542` |
| endpoint generation 隔离 | `platform/conversation_host_transport.rs:89-100` | `:174-197` |
| generation 记录完整性 | `bin/licoup/conversation_host.rs:39-101` | `:556-577` |
| 更新交接 pending → claimed | `domain/client_state_migration.rs:371-403` | `:1631-1649` |
| 交接不匹配 / 被拒 | `:486-503` | `:1531-1562` |
| store 步骤前崩溃 | `claim_update_handoff` 入口 `:178-186`；failpoint `:267` | `:1513` |
| store 步骤后、ledger 写入前崩溃 | failpoint `:274` | `:1479` |
| ledger 写入后崩溃 | failpoint `:277` | `:1513` |
| turn 中途被杀后的冷恢复 | `crates/licoup-conversation/tests/cold_recovery.rs` | `:9`、`:76`、`:149`、`:212` |
| claim 后清理失败不得回滚 | `client_update/native_runner/script.rs` | `domain/client_state_migration.rs:1562` |

## 5. 数据边界与格式边界

### 5.1 状态根

`portable_data_dir()`（`platform/paths.rs:24`）解析状态根。产品写入的子项：

| 路径 | 归属 | 格式 |
| --- | --- | --- |
| `client-state/` | `platform/client_state/paths.rs:13` | collections JSON、SQLite 存储 |
| `client-state/conversations/conversations.sqlite3` | `crates/licoup-conversation/src/store/mod.rs:46` | SQLite，schema **12** |
| `client-state/adaptive-flywheel/strategies.sqlite3` | `domain/adaptive_flywheel/store.rs:17` | SQLite，schema **2** |
| `client-state/migrations/` | `domain/client_state_migration.rs:20-22` | ledger、domain marker、更新交接 |
| `llm-gateway/` | `platform/llm_gateway_service.rs:44` | 服务状态、autostart、client token |
| `agent-workspace/` | `platform/agent_workspace.rs:15` | turn 默认工作目录 |
| `opencode-serve/` | `platform/opencode_serve/policy.rs:19` | 状态、pid、lock |
| `telegram-gateway/` | `platform/gateway_runtime/channels/telegram/binding.rs:18` | bindings、bot token |
| `gateway/` | `platform/gateway_runtime/service.rs:12` | gateway 运行时状态 |
| `client-autostart/` | `platform/client_autostart.rs:16` | autostart 标记 |
| `catalog-cache/` | `platform/catalog_cache_store.rs:7` | catalog 缓存 |
| `mcp-transfer-plans/` | `platform/mcp_approval_plan_store.rs:16` | 批准计划 |
| `openclaw-gateway/` | `platform/openclaw_gateway/policy.rs:5` | 配置与运行时 |
| `licoup/secure-mesh/command-replay.sqlite` | `domain/secure_mesh_command_runtime.rs:19` | 重放账本 |
| `.licoup-workspace.json` | `domain/client_state_migration.rs:737-741` | workspace 清单 |

### 5.2 带版本的文档

迁移 frontier 覆盖的每份文档都带显式版本，下表的值不得改动。带版本与否在下文明确区分，因为并非所有持久化状态都带版本（见数字版本文档表后的说明）。

| 常量 | 值 | 写入位置 |
| --- | --- | --- |
| `FRONTIER_SCHEMA` | `v0.0.1:client-state-migration-frontier-1` | 内嵌资源，只读 |
| `LEDGER_SCHEMA` | `v0.0.1:client-state-migration-ledger-1` | `client-state/migrations/ledger.json` |
| `DOMAIN_MARKER_SCHEMA` | `v0.0.1:client-state-domain-marker-1` | `client-state/migrations/domain-state/<domain>.json` |
| `UPDATE_HANDOFF_SCHEMA` | `v0.0.1:client-update-handoff-1` | `client-state/migrations/update-handoff.json` |
| `STATE_SCHEMA_VERSION` | `v0.0.1:schema:definition-1` | `client-state/<collection>.json` |
| `TARGET_DISCOVERY_CACHE_SCHEMA` | `licoup.target-discovery-cache.v1` | `client-state/target-discovery-cache.json` |
| （内联，交接被拒） | `v0.0.1:client-update-handoff-rejection-1` | `client-state/migrations/update-handoff.json.rejected` |

迁移期间准入的数字版本 JSON 文档（`domain/client_state_migration.rs:1050-1055`）。
其中两个有专用处理函数，其余共用 `migrate_json_schema`（`:1130`）：

| 文档 | 版本 | 处理函数 |
| --- | --- | --- |
| `.licoup-workspace.json` | 1 | `migrate_json_schema` |
| `client-state/appearance-preferences.json` | 1 | `migrate_json_schema` |
| `client-state/agent-tab-order.json` | 1 | `migrate_agent_tab_order`（`:1102`） |
| `client-state/agent-tool-allowlists.json` | 1 | `migrate_json_schema` |
| `client-state/current-client-view.json` | 1 | `migrate_json_schema` |
| `client-state/mobile-home-layout.json` | 2 | `migrate_json_schema` |
| `client-state/skill-hub-preferences.json` | 1 | `migrate_json_schema` |
| `client-state/mobile-relay/config.json` | 2 | `migrate_mobile_relay`（`:1117`） |

并非所有持久化文档都带版本：`telegram-gateway/channel.ready` 仅含 `channelId`、
`state`、`botUsername`（`platform/gateway_runtime/channels/telegram/mod.rs:44-53`）。
带版本的文档即上表与前一表所列。

### 5.3 迁移工具：复用什么、新增什么

原样复用：

- frontier 资源及其校验（边连续、id 唯一、每边一个已编译处理函数）——
  `domain/client_state_migration.rs:545-598`
- ledger 与 per-domain marker 作为持久进度记录
- `ConversationStore::open_for_migration` 与
  `AdaptiveFlywheelStore::open_for_migration` 作为步骤期间唯一写入方
- `:723` / `:1007` 已有的域路由
- `:165-173` 的排他 `admission.lock` flock

工具中新增（今天不存在）：

- 流水线阶段 `Checking → WaitingForQuiescence → Snapshotting → Migrating →
  Verifying → Ready`。**这些名字在代码树中一个都不存在**；当前实现是一次同步
  的 `admit()`，返回 `AdmissionResult`
- 带枚举动作的 `doctor` / `recover` 修复模式
- 回滚。今天迁移是单向的：一旦接纳了更高的产品版本，旧二进制会被永久拒绝
  （`:623` 的 `reject_older_binary`，错误码 `state_newer_than_binary`）

今天的触发方式是隐式的：桌面在存储加载之前把准入作为第二个生命周期步骤
（`apps/desktop/lib/src/application/controller/client_lifecycle_facade.dart:75-78`，
顺序由 `tests/contract/client/client-state-migration.test.mjs` 钉住）。
`licoup state admit <data-root>`（`ffi/commands/state.rs:32-37`）是安装器已在
使用的显式形式。

## 6. 模块归属声明

每个任务在运行期间独占下列路径。若某任务需要改动他人路径，它必须先在独立分支
上落地该改动。

| 任务 | 独占写入范围 |
| --- | --- |
| #285 | 本文；`docs/README.md` 的登记项 |
| #286 | 新建 `crates/licoup-application/**`；workspace 成员列表 |
| #287 | `crates/licoup-native/src/domain/**`；`crates/licoup-agent-runtime/**` |
| #288 | `crates/licoup-native/src/bin/licoup/**`；`crates/licoup-native/src/ffi/commands/**` |
| #289 | 新建 `crates/licoup-mcp/**`；`crates/licoup-native/src/core/mcp/**`；`crates/licoup-native/src/bin/lico-subagent-mcp.rs`；`crates/licoup-native/src/bin/lico-conversation-mcp.rs` |
| #290 | `tests/contract/**`；新建一致性测试根；`tools/regression/**` |
| #291 | `crates/licoup-native/src/ffi/**` 组合根；`crates/licoup-native/src/bin/**` 各 root |
| #292 | `schemas/**`；`apps/desktop/packaging.modules.json`；`docs/**`（本文除外）；删除被取代的 MCP 路径 |
| #293 | 不占源码路径；仅产出证据 |
| #294 | `crates/licoup-native/src/platform/**` 监督部分；桌面生命周期路径 |
| #295 | `crates/licoup-native/src/domain/client_update/**`；`crates/licoup-native/src/domain/client_state_migration.rs` 的交接部分 |
| #296 | 新建迁移工具 crate；`crates/licoup-native/src/domain/client_state_migration.rs` 仅在 #295 落地后 |

有三处共享表面必须串行，绝不可并发编辑：

1. **`crates/licoup-native/Cargo.toml`** —— 每个拆 crate 的任务都会新增成员。逐个落地。
2. **`crates/licoup-native/src/ffi/commands/mod.rs`** —— 162 项注册表。#288 拥有它；
   #289 与 #291 只读。
3. **`apps/desktop/packaging.modules.json`** —— #292 拥有它；任何重命名或新增二进制的
   任务必须在 #292 之前落地，而不是在其期间。

## 7. 冻结内容

以下内容必须精确保留，且已由现有测试验证：

- 162 条已注册命令路径及其准入选项集
- 29 个 RPC 方法、四种信封形状、45 个错误码
- 两份 MCP 目录（10 与 5 个工具）、两组身份三元组、两套兼容修订集，以及
  `licoup.mcp.error.v1` 主体
- 回执 schema：`licoup.subagent.receipt.v3`、`licoup.subagents.v3`、
  `licoup.subagent.readiness.v2`
- 7 个二进制名与 5 条打包映射
- 仅回环、钉住 Host、无 Origin、bearer 认证的 MCP 传输及其 32/64/8 上限
- 本地管理员与成员 actor 的区分，包含 CLI 发帖路径上刻意保留的作者 id 信任
- endpoint 命名方案、500 ms 属主检查、300 s 空闲宽限，以及单向迁移立场
- §5 中的每一个 schema 版本字符串

改动上述任何一项都属于产品决策，而非重构步骤。
