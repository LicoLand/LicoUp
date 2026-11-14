# 会话 Profile（智能体人格）

| 关系 | 权威 |
| --- | --- |
| 产品范围 | [客户端功能](CLIENT-DESKTOP.md) |
| Profile 契约 | `contracts/conversation_profile.dart` |
| 持久化端口 | `frontend/shared/messaging/conversation_profile_store.dart` |
| 注册表 | `frontend/shared/messaging/conversation_profile_registry.dart` |
| 创建对话框 | `frontend/features/agents/ui/conversation/conversation_profile_create_dialog.dart` |
| 原生 intent | `licoup-conversation` `ProfileIntent`、`DirectTurnExecutionContext` |

本文档负责会话 Profile 特性的契约——Profile 是什么、如何创建、它的偏好
如何到达派发层。

## 术语

- **会话 Profile**（`ConversationProfile`）：基于某个本机 Agent 能力构建的
  持久人格。携带显示名称、吉祥物头像、底层 Agent、模型、思考强度，以及
  高级偏好（权限模式、工作目录、上下文窗口、默认提示词）。稳定主体是
  `profile:<id>`——与底层 Agent 的 `agent:<agentId>` 身份互相独立。
- **直聊会话**：以 `isGroup=false` 创建的规范会话，承载该 Profile 成员。
  在联系人列表中显示为人格行，并从群组界面中排除。
- **Profile intent**：按成员持久化的 `ProfileIntent` 字段——
  `preferredModel`、`preferredReasoningEffort`、`preferredPermissionMode`、
  `preferredEnvironment`、`preferredInstructions`、`preferredContextWindow`。
  原生派发在 Profile 获准执行轮次时应用它们。

## 生命周期

1. 消息列表 `+` 菜单在原有“新对话”“新群组”旁提供**创建智能体**。
2. 创建对话框收集：吉祥物头像（随机预选）、显示名称，以及由真实适配器
   目录驱动的 Agent → 模型 → 思考强度级联。高级选项默认收起：上下文
   窗口、工作目录、默认提示词，以及权限模式选择器——仅当所选 Agent
   声明了权限模式才渲染，绝不虚构选项。
3. `CreateConversationProfile` → `createProfileConversation` 依次执行
   `conversation.create`（`isGroup=false`，人类 owner + `profile:<id>`
   成员）、把 Profile 设为 assistant、写入 profile intent。成功后注册
   Profile、回填 `conversationId`，并发出 `ConversationProfileCreated`。
4. Profile 持久化在 `client-state/conversation-profiles.json`（schema
   版本 1）。组合启动时水合一次，跳过畸形条目，且不会触发回写。

## 界面

- 联系人列表渲染 Profile 行——吉祥物头像、Profile 名、预览、时间、未读
  徽标、行级加载骨架——归入“智能体”筛选，与既有行统一排序。
- 建群对话框把 Profile 列为可选成员；Profile 以 `profile:<id>` 主体加入
  并在建群后写入持久 intent，与底层 Agent 自身成员身份保持区分。
- 选中 Profile 行经规范会话面板打开其直聊；不带 @ 的消息派给该
  Profile，因为它是会话的 assistant。

## 派发应用

`apply_admitted_runtime_fields` 在每条获准路径上把持久 intent 映射进派发
参数——常规直发轮、连续性轮次、stdio RPC 直发路径。
`preferredInstructions` 在 assistant 私训之后、成员角色块之前注入轮次
guidance；`preferredContextWindow` 透传为 `contextWindow` 派发参数。
具体运行时适配器是否消费 `contextWindow` 属于适配器自身的契约。

## 边界

- Profile 是客户端人格数据；不授予所选 Agent 声明之外的任何能力。
- 尚无直聊会话的 Profile 仍会出现在建群成员列表——成员创建与联系人行
  相互独立。
- 尚无删除 Profile 的界面；在该生命周期设计落地前记录持续保留。
