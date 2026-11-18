# 会话发送门禁

| 关系 | 权威来源 |
| --- | --- |
| 产品范围 | [客户端功能](CLIENT-DESKTOP.md) |
| 视觉语言 | [设计系统](DESIGN-SYSTEM.md) |
| 未读与行点击契约 | [消息未读导航](MESSAGING-UNREAD-NAVIGATION.zh-CN.md) |
| 门禁行渲染 | `frontend/features/agents/ui/agent_conversation_pane/` |
| 门禁原因码 | `contracts/target_candidate.dart` |

本文档是会话发送门禁的交互契约：输入区上方报告「为何不可发送」的那一行，
以及在可用性仍在解析时替代它的加载指示。

## 术语

- **运行时绑定门禁码**：`native_agent_executable_not_detected`、
  `native_agent_runtime_profile_unavailable`、`runtime_message_send_unavailable`。
  它们描述扫描与选中时绑定所解析的本地可执行程序或运行时配置；重新扫描是其
  救济手段。
- **解析中**：`ScanAgents` 扫描或选中时的可执行程序绑定（`native.phase ==
  loading`）仍在进行。此窗口内观察到的门禁状态是过渡态。
- **列表成员资格**：消息侧栏只渲染发现结果（扫描出的 `TargetCandidate` 中
  `isConversationAgent` 者加上各智能体的会话目录）。行绝不硬编码——智能体出现
  在列表中，仅因为扫描在宿主上发现了它。

## 渲染契约

已列入列表的智能体必然已被发现——对它而言「未检测到」永远不可能是最终结论，
只会是过渡的扫描状态。因此：

- 当运行时绑定族门禁码处于**解析中**时，门禁区渲染加载指示（小型进度指示器
  配弱化的「正在检测本地运行环境」文案）。不出现警告图标、结论文案或操作按钮。
- 当扫描与绑定**完成**而门禁码仍然存在时，渲染诚实的不可用行：本地化原因
  文案加重新扫描操作。确实缺失的可执行程序依旧可解释——加载指示是一种状态，
  绝不充当永久替身。
- 运行时绑定族之外的门禁码（例如 `antigravity_auth_required` 或
  `virtual_machine_connection_invalid`）永远不是过渡态：即使扫描进行中，也
  立即渲染其常规行。

## 边界

- 本契约只覆盖发送门禁行。发送失败仍走独立的发送失败行及其原始原因。
- 解析状态来自既有的扫描与目录加载信号；门禁自身不引入额外扫描。
- 列表由发现驱动是属性陈述而非视觉状态：侧栏行必须继续来自扫描目标与已加载
  会话目录，绝不来自固定的产品清单。
