# Lico Arc 智能体对话适配标准

本标准是新增或变更智能体适配器的唯一入口。它覆盖本机发现、配置、会话生命周期、实时事件、精确续聊、清理、隐私、产品 UI 和 readiness 证据。仅能读取历史或只能启动新会话的集成，不得登记为可发送的对话适配器。

机器契约位于 `packages/contracts/client/agent-conversation-adapter.schema.json`；可复制并填写的起始清单位于 `packages/contracts/client/fixtures/agent-conversation-adapter/template.json`；每个已打包智能体的 canonical manifest 位于其相邻的 `manifests/<agentId>.json`；reducer 输入清单位于 `crates/lico-client-native/resources/agent-conversation-drivers.json`。门禁以 Draft 2020-12 校验模板和全部 canonical manifest，并要求 manifest、packaging target 与 driver inventory 是同一个精确集合。模板只是示例，不能代替实际 manifest。

## 1. 框架能力调查

适配前必须从智能体框架的官方本机接口确认以下事实，并记录具体方法名或端点。不得用 fixture、非官方数据库写入、窗口脚本或“最近会话”替代缺失能力。

| 能力 | Lico Arc 要求 | 不满足时 |
| --- | --- | --- |
| 发现 | 确认本机 executable、版本和官方 transport | `blocked` 或不纳入产品矩阵 |
| 新建 | 返回真实 native session/thread ID | 禁止发送 |
| 精确续聊 | 调用方提供一个 ID，框架恢复同一个 ID；不得选择 latest | `exact_session_resume_unavailable` |
| 发送 | prompt 走 stdin、JSON-RPC 或 HTTP body，不进 argv | `official_native_lane_missing` |
| 实时流 | 在结束前提供 chunk/progress；事件归属同一 session/turn | 保持 `sendEnabled=false` |
| 结构化过程 | reasoning/tool call/tool result/error 有稳定关联 | C-02 保持未验证或失败 |
| 权限 | 官方 approval 请求可在产品中明确批准或拒绝 | C-03 保持未验证；默认拒绝 |
| 取消 | 必须持有真实活跃 turn handle | 未实现时声明 unsupported，不得只杀无关进程 |
| 清理 | 官方 delete/close 或完全隔离的一次性 data root，并二次确认缺席 | `safe_cleanup_unavailable` |
| 历史 | 官方 list/read 能按 exact ID 回读两轮结果 | P-06 不通过 |
| 配置 | binary、认证、模型、reasoning、permission 的 authority 清晰 | 不得由 Flutter 猜测优先级 |
| 生命周期 | 明确进程监管、会话作用域、并发上限、tracked session 上限 | 不得创建无界进程或无界 session map |

### Transport 选择顺序

1. 优先官方 ACP、JSON-RPC、app-server 或明确版本化的本机 HTTP/SSE 接口：它们必须把 prompt、session ID、工作目录和设置放进协议字段。
2. 官方 streaming-input 仅在一个受监督长驻进程能够承载多轮、返回真实 native ID、逐事件流式输出时采用；若进程退出后无法恢复，manifest 必须把 session scope 和限制写明，不能借用 `--resume <id>` 补洞。
3. 官方 SDK 只有在它能连接产品所指的同一原生会话、暴露精确 ID 和完整事件时才可作为 transport；“在同一模型上新建自定义 agent”不等于续接产品会话。
4. 仅提供 TUI、latest/continue、argv prompt/ID、非结构化屏幕输出或私有数据库的框架保持 blocked。不得用 PTY 解析、窗口自动化或状态库修改伪造协议。

每次评估都在 driver inventory 记录最终协议、lane family、支持矩阵和 blocker；官方接口升级后必须重新调查，旧 blocker 不能作为永久假设。

## 2. 必备接口

所有可发送适配器都通过同一个 `AgentDispatchLane` 暴露执行面；发现、历史与清理仍使用各自的 canonical client port，不得为了“接口统一”复制第二套执行器：

```text
target discovery ─┐
                  ├→ AgentDispatchLane.capabilities → openOrResume
                  │  → sendStreaming → cancel（仅支持时）
native history ───┴→ exact history readback
native cleanup ─────→ cleanup + absence confirmation
```

- `openOrResume(agentId, nativeSessionId?)`：空 ID 建立新会话意图；如果框架只能在首个 send 时分配 ID，此处允许暂为空，但首个 terminal result 必须返回真实 ID。非空 ID 的 open 失败、空返回或不同 ID 返回都必须立即失败关闭，调用方不得继续用空 ID send 并静默新建分支。
- `cleanup(agentId, nativeSessionId)`：统一产品接口必须调用 native canonical cleanup；仅验收脚本拥有 cleanup 不算产品能力。成功后还要由官方 list/read、受监督进程状态或隔离 data root 缺席检查二次确认。
- `sendStreaming(...)`：先产生 `dispatch.turn.started`，随后可产生 `agent.message.chunk` 与结构化过程事件，最后只产生一个 terminal event。
- terminal result 必须返回 `nativeSessionId`、`turnId`、有效设置和成功/错误状态；续聊 ID 不由 Flutter 推断。
- `conversations list --agent <id>` 与 GUI 必须读取同一官方历史；CLI 与 GUI 的 send readiness 完全一致。
- native session ID 只进入受保护、可恢复的映射；公开 route history 仅保存 opaque handle 和 digest。

## 3. 配置清单

贡献者需先完成官方能力调查，再提交符合 schema 的 adapter manifest，并明确：

1. `identity`：稳定的 `agentId`、`driverId`、`runtimeProtocol`、`packagingTargetId`。
2. `officialCapabilityAssessment`：实现前完成的官方接口评估，记录接口名、实际评估版本、固定 version/capability probe、新建、精确续聊、实时流、历史和清理方法，以及至少一个官方引用；不得记录本机路径、账号或会话数据。
3. `transport`：协议家族、官方来源、prompt/continuity/working-directory channel、framing、session scope、固定启动参数。
4. `configuration`：允许的 binary 环境变量名，以及认证、模型、reasoning、permission 的唯一 authority。
5. `operations`：discover/open/send/stream/resume/cancel/cleanup/history 与可选能力逐项标为 supported、unsupported 或 blocked；blocked 必须给安全 blocker code，其他状态禁止携带 blocker。
6. `events`：列出实时与 terminal event kind，并强制 session/turn ownership。
7. `lifecycle`：进程监管方式、清理作用域、最大并发 transport 与最大 tracked session 数。
8. `privacy`：prompt/native ID 不得进入 argv；输入输出有界；只投影结构化事件；证据脱敏；清理能力如实声明。
9. `routedContext`：路由交接使用版本化 distillation package；目标、当前状态、决策、约束与待办不可缺失；包有字节上限，只携带 opaque digest source references，不携带原始对话；digest 缺失或 fidelity 失败必须失败关闭。
10. `productIntegration`：CLI、GUI、路由必须共用 `AgentDispatchLane`、canonical readiness 和同一官方历史 authority；最终真实回复必须进入 thread 与下一次 distillation。
11. `acceptance`：P-01…P-10、C-01…C-06、真实本机转发、terminal 前实时输出、同一 native session、至少三次连续 Release UI 通过、双向续聊、exact artifact 与产品 UI 都必须验证。

配置不得包含账号、token、cookie、真实路径、设备身份、publisher/team/tenant、原始 prompt 或会话正文。运行时认证由智能体自身或平台安全存储管理。

提交前先复制模板、替换示例值，再运行 `npm run client:verify:agent-adapter-standard`。模板本身也是门禁 fixture；schema 变更若未同步模板会直接失败。

## 4. 实现顺序

1. 在 native platform 层实现一个 official transport driver；不得新建第二套 controller 执行器。
2. 将 adapter 加入 `RuntimeAdapter`、packaging target list 与 driver inventory，三处 ID 必须一一对应。
3. 实现 exact-ID open/resume、流式事件归属、终止结果、官方历史回读和安全清理。
4. 通过 stdin JSON 接入 CLI；普通 CLI 必须受 canonical readiness 约束。
5. 通过 `AgentConversationService.sendStreaming` 接入 Flutter；过程事件在会话 timeline 内可见，最终回复写入 thread。
6. 路由路径复用相同 lane；最终回复成为后续 distillation 输入，禁止用状态占位代替。
7. 更新 reducer-owned adapter readiness projection 与本标准的能力调查结果；未实现能力明确 unsupported/blocked。平台/服务 support matrix 不是适配器 readiness 权威。

## 5. 验收与提权

静态/fixture 测试只能证明协议形状，不能设置 ready。正式提权顺序为：

1. 运行 native driver 单元与 fail-closed 负向测试。
2. 运行 core live 双向 A/B：原生新建 → Lico Arc exact resume；Lico Arc 新建 → 原生 exact resume。
3. 每轮验证真实 ID、实时 chunk、结构化事件、有效设置、历史回读、隐私边界和清理。
4. 使用 acceptance-only Release build 驱动 Flutter composer、timeline、process card、final reply 和同 ID follow-up；仅使用 Release sidecar 的 CLI 不算 P-10。该 artifact 只用于验收，不能表述为最终 GitHub Release 或商店包。
5. 同一 acceptance Release artifact 的 P-10 产品 UI 连续成功至少三轮；每轮都必须证明真实本机转发、terminal 前实时输出和同一 native session 续聊。product 与 core 必须由同一个单次 challenge 绑定，并校验模型、artifact、sidecar、adapter manifest 与 continuity digest。manifest 变化必须使既有证据失效。证据只保存 digest、布尔事实、计数和安全错误码。
6. reducer 写入 adapter readiness；仅 `status=ready && sendEnabled=true` 才可进入产品发送与路由。验收完成后必须重新构建普通 Release artifact；验收 digest 不得冒充普通打包或 GitHub Release digest。

推荐命令：

```bash
npm run client:verify:agent-adapter-standard
npm run client:verify:agent-conversation-parity
npm run client:verify:agent-conversations:self-test
npm run client:verify:agent-conversations:release-ui
```

最后一个命令在真正的 Flutter 产品 E2E driver 不存在或失败时必须失败关闭。

### P/C 语义表

| ID | 稳定语义 | 必须证明的事实 |
| --- | --- | --- |
| P-01 | `baseline-binding` | Native 与 Arc 绑定同一受控 runtime、版本类别、cwd 与有效设置。 |
| P-02 | `native-session-creation` | Arc 新建返回真实 native session/thread ID，且原生历史可回读。 |
| P-03 | `bidirectional-exact-resume` | Native→Arc 与 Arc→Native 都按调用方 ID 续接同一会话，不选择 latest。 |
| P-04 | `deterministic-final-result` | 最终文本或结构化副作用以确定性 canary/digest 比对。 |
| P-05 | `effective-settings-parity` | cwd、模型、reasoning、permission/sandbox 等有效设置一致。 |
| P-06 | `history-readback-and-rendering` | 两轮历史顺序与 Arc 投影、过程折叠渲染一致。 |
| P-07 | `error-cancel-timeout-parity` | 无效会话、认证、模型、拒绝、取消和超时均失败关闭且可行动。 |
| P-08 | `privacy-and-process-boundary` | prompt、路径、凭据、native ID 不进入 argv、日志或公开证据；输出有界。 |
| P-09 | `isolation-and-cleanup` | 成功和失败路径都清理隔离状态，并二次确认会话缺席。 |
| P-10 | `exact-release-product-ui` | 同一 Release artifact 连续三轮贯通 composer、sidecar、native history 与 renderer。 |
| C-01 | `streaming-delta` | chunk 顺序、去重、terminal 边界、打断状态与渐进 UI 一致。 |
| C-02 | `reasoning-and-tool-trace` | reasoning/tool/result/error 保持 session/turn 关联与隐私投影。 |
| C-03 | `approval-lifecycle` | approve/deny/cancel/timeout 绑定同一请求；只有明确用户操作可批准。 |
| C-04 | `attachments-and-multimodal` | 类型、顺序、digest、大小边界与目标可见结果一致。 |
| C-05 | `interrupt-and-steer` | 支持时证明 in-flight interrupt、steer、resume 与最终状态；否则明确 unsupported。 |
| C-06 | `usage-and-status` | 原生状态、usage、completion reason 保持语义；不可用时不得伪造为零。 |

## 6. 变更审查清单

- [ ] 使用官方本机 transport，并记录稳定版本能力。
- [ ] prompt 与 continuity ID 均不进入 argv。
- [ ] 新建与 exact resume 都返回并保持同一 native ID。
- [ ] chunk 在 terminal event 之前出现在产品 timeline。
- [ ] reasoning/tool/error 事件具备 session/turn ownership。
- [ ] approval 默认拒绝；产品批准路径存在后才声明支持。
- [ ] cancel 只操作真实活跃 handle；否则声明 unsupported。
- [ ] cleanup 后再次 list/read 确认会话缺席。
- [ ] CLI、GUI、路由共用 readiness 和 `AgentDispatchLane`。
- [ ] 最终真实回复进入 thread 与 distillation，不保存原始 ID 到 route history。
- [ ] P-01…P-10、适用的 C 项、三轮 Release UI 证据均通过。
- [ ] 未 ready 状态与 blocker 已由 canonical readiness reducer 在 UI 如实投影；平台/服务 support matrix 不复制适配器状态。
