# LicoUp Subagent MCP

[English](subagent-mcp.md) · 简体中文 · [Agent 适配器架构](../architecture/AGENT-ADAPTERS-ARCHITECTURE.zh-CN.md)

已实现权威由 `domain/subagent_mcp`、参数化 `core/mcp` 引擎、
`licoup-agent-runtime`、`licoup-agent-adapters` 与私有 Canonical
Conversation store 共同组成。公开契约冻结在
`schemas/subagent_mcp/subagent_mcp.schema.json`。

## 公共契约

- 主协议修订：`2025-06-18`；兼容入站修订：`2025-11-25`
- 服务器：`lico-up-subagents` `0.11.0`
- 传输：桌面客户端托管的已认证回环 Streamable HTTP 服务
- 供应商入口：不含工具定义的轻量 stdio connector
- 本 Mesh 供应商：Codex、Cursor、Antigravity

准确且有序的工具目录为：

1. `lico_assistant_profiles`
2. `lico_assistant_workflow_execute`
3. `lico_assistant_workflow_inspect`
4. `lico_assistant_workflow_cancel`
5. `lico_subagents_list`
6. `lico_subagent_probe`
7. `lico_subagent_delegate`
8. `lico_subagent_continue`
9. `lico_subagent_cancel`

所有输入 schema 都是封闭的。connector 不含目录与供应商逻辑；每个 stdio
帧只执行一次 HTTP 尝试。

## Assistant Profile 与临时工作流

前四个工具继续遵守 designated Assistant 契约。只有当前被指定为该 Conversation
Assistant 的准确活动 Agent Membership，才能读取排序后的 Membership Profile，
或执行、检查、取消 Assistant 创作的临时工作流。检查与取消会先从持久 run 中恢复
其 Conversation 和 Assistant Membership，再认证 caller；调用方不能通过工具输入
改选另一份权威。

工作流执行只接受封闭的 workflow、binding、filter、input 与 idempotency 字段。
持久 host 获准接纳 run 前，每个引用的 binding 都必须解析为活动 target Membership，
且存在已安装、可执行的 `runtime.message.send` 路由。持久 Conversation host 始终是工作流与 turn 的唯一
所有者；MCP 服务不会创建第二套 scheduler、history 或 terminal output store。
原生身份、路径、prompt 与 Agent output 不进入 Profile 或工作流回执。

## 权限与调用谱系

每项效果都绑定到已认证 caller Membership，以及同一 Canonical Conversation
中的准确 target Membership；二者都必须是活动 Agent Membership。store 在目标
运行效果开始前持久提交 dispatch claim。自调用、重复活动边、跨 Conversation、
重复祖先、环路以及超过四层的调用都会在零效果状态下拒绝。

`lico_subagent_delegate`、`lico_subagent_continue` 与 `lico_subagent_cancel`
的入站 `tools/call` 记入 Canonical Conversation 的 `subagent_mcp_inbound`。
Mesh 证明读这些行、`subagent_dispatch_claims` 与 target Membership 的
PersistentTurn，不刮取 caller Agent 会话或投影出的 `tool-call` 部分。

委派只通过 Membership 作用域 PersistentTurn。续接从私有 runtime binding
解析 adapter 自有的准确原生身份；调用方不能提交或读取原生 session/path。取消只
寻址活动 claim。原生取消结果不确定时进入 `reconciliation-required`，绝不伪报完成。

## Registry、准入与 readiness

`McpCallerIntegration` 独占供应商注册、安装、身份、readiness、移除与新会话行为。
`SubagentRuntimeAdapter` 独占能力、准确原生身份、send、continue、observe、活动
cancel、cleanup 与状态投影。唯一 registry 连接两类 port；MCP application
不含供应商分支。

执行准入与 Conversation readiness 观察相互独立。执行要求准确供应商身份、已注册
adapter、请求操作能力，以及已安装且可执行的 `runtime.message.send` 路由。已认证的
直接 MCP caller、同一 Conversation 内活动且非自身的 Membership、持久 claim 规则、
选定模型与服务健康仍是彼此独立的 fail-closed 门禁。准入后遇到的首个 discovery、
binding、authentication、permission、launch、protocol、session、model、dispatch 或
readback 失败会保留其类型化阶段契约。

Conversation readiness 不会合成 transport 或 permission，也不会否决执行；它仅作为
`lico_subagent_probe` 与其它 inventory 投影的观察信息。

`lico_subagents_list` 与 `lico_subagent_probe` 是只读 inventory/readiness 表面。
它们只检查准确的 Codex、Cursor、Antigravity target，不启动供应商进程、不刷新
history、不打开 model owner，也不持久更新 discovery state。其投影只包含安全的
供应商、状态、driver、readiness、能力与 blocker 事实。

## 供应商行为

| 供应商 | Caller 注册 | Target 通道 | 指令策略 | 活动控制 |
| --- | --- | --- | --- | --- |
| Codex | 外部 `lico-up-codex` package `0.2.0` | App Server stdio JSON-RPC | 原生 `developerInstructions` | 原生 steer 与 interrupt |
| Cursor | 命名空间 user MCP entry | PTY 上的 create-chat/resume CLI | 一段普通、无标记、临时 wire prefix | 监督式活动 cancel 后准确 resume |
| Antigravity | 命名空间 user MCP entry | OAuth/权限预检、Hook receipt、PTY CLI | 一段普通、无标记、临时 wire prefix | 监督式活动 cancel 后按 Hook 身份 resume |

Cursor 与 Antigravity 不接收 `privateInstructions`。生成指令在 driver 调用前被
剥离，不写入可见 Event/Part；准确用户 Event 文本始终是 canonical。

## 本地安全与隐私

HTTP 只监听回环。私有 discovery 保存临时、按供应商区分的 bearer token，并在
客户端状态目录内加固。MCP session 与连接数有界；关闭时只删除当前 supervisor
所属 generation。

注册变更要求一次 digest 绑定且只能消费一次的批准。Cursor 与 Antigravity 只修改
LicoUp 命名空间且确认归属的 entry；外来 entry、多个 Antigravity 配置候选或配置
发生变化都会 fail closed。同一次批准还会通过供应商 user Skill Hub root 交付内嵌的
`lico-up-subagents` Skill；外来 Skill 内容同样 fail closed。公开响应不包含配置正文、凭据、endpoint、原生 session、
路径、prompt 或 Agent output。

## 相互独立的验证路径

`tests/product-e2e/cli/subagent-mcp/upstream.mjs` 验证启动识别。它先初始化桌面
客户端托管的服务并核对准确、有序的工具目录，再并发执行 Codex、Cursor 与
Antigravity 三个独立启动探针。每个探针只读取供应商的标准 MCP
startup/list/registry 表面，不发送 turn、不创建 Conversation，也不安装、移除或
改写配置。该验证不依赖 Codex 自定义插件。Codex 通过仅在当前进程生效的配置
override 接收一份标准 MCP 声明，该 override 不会持久化。Cursor 与 Antigravity
使用各自支持的只读 `mcp list` 命令；若缺少归 LicoUp 所有的注册，则只报告
`installer_configuration_required`，不会修改供应商配置。

`tests/product-e2e/cli/subagent-mcp/downstream.mjs` 是独立的直接效果验证路径。
默认模式是零效果预检。只有显式 `--live` 才能准备本地验证 Conversation，并针对
每个尚未验证的 target 直接向已认证 Streamable HTTP 服务发送一次
`lico_subagent_delegate`。该路径不启动 Caller Agent 进程或 Caller Agent
Conversation。通过必须同时具备匹配的入站 delegate、持久 dispatch claim、选中的
target Membership 与其 PersistentTurn dispatch 状态；既不读取也不保留 Agent
输出。

预检通过既有 LicoUp target 与 Agent Hub 表面解析三个 Agent 的安装版本、可执行
`runtime.message.send` 路由及其报告的模型清单。Agent Hub 使用既有、有界的
`--version` recipe 调用 target discovery 的准确可执行绑定，其中 Cursor 必须使用
绑定的 `cursor-agent`；它不会重新扫描 `PATH`，也不会把绑定投影到 card 或 receipt。
Conversation readiness 不参与准入。随后，验证器使用实际会采用的非自身 caller
身份验证 MCP 服务。版本缺失或不安全、缺少可执行路由、批准模型不可用、服务不健康
时，都会在创建 Conversation 或产生付费工作前停止。

现场模型选择仅允许首个可用的低成本批准模型：Codex 依次为
`gpt-5.3-codex-spark`、`gpt-5.4-mini`，Cursor 为 `composer-2.5`，Antigravity
为已配置的 Gemini 3.7 Flash 别名；不存在 Auto 或昂贵 fallback。现场路径在最终
三个 Agent 的主候选均来自共享 Conversation 验证模型权威，只有 Codex Mini
fallback 在该路径边界补充。现场路径在最终重读 Manifest 到写入 target 记录期间
持有唯一、未跟踪的排他 lease。它会在创建 Conversation 或付费前跳过 App Version、
Target Agent 与 Target Agent Version 完全匹配的通过凭据；每个其余 target 最多执行
一次 `tools/call`，内部从不重试，也不会用超时破坏其它现场 lease。结构化
`licoup.mcp.error.v1` 结果只有在 code、stage、retryability 与 recovery 都属于封闭
安全集合时才会保留；Notes 只能写入其中白名单 reason code。

最近 App Version 的 Manifest 位于
`tests/product-e2e/cli/subagent-mcp/interop-manifest.yaml`。其 key 为 App
Version 加 Target Agent，Codex、Cursor、Antigravity 各至多一行。跳过还要求当前
Target Agent Version 一致且 `Results: passed`。每行严格按顺序包含 App Version、
Caller Agent、Caller Agent Version、Target Agent、Target Agent Version、
Results、Notes；Caller 字段表示已认证的非自身 Membership。Results 只能是
`passed` 或 `failed`，Notes 为空或白名单 reason code。写入使用原子替换；封闭解析器
拒绝重复、额外、乱序或不安全值。endpoint、token、prompt、本地标识符、路径、原生
身份、模型与运行内容都不会进入 Manifest 或控制台回执。
