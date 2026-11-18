# 消息列表加载呈现

| 关系 | 权威 |
| --- | --- |
| 产品范围 | [客户端功能](CLIENT-DESKTOP.md) |
| 视觉语言 | [设计系统](DESIGN-SYSTEM.md) |
| 未读与行点击契约 | [消息未读导航](MESSAGING-UNREAD-NAVIGATION.zh-CN.md) |
| 加载条组件 | `frontend/shared/messaging/messaging_loading_bar.dart` |
| 骨架动画 | `frontend/shared/ui/lico_skeleton.dart` |
| 行渲染 | `frontend/features/agents/ui/messaging/messaging_contact_list.dart` |

本文档拥有消息对话列表的加载呈现契约——哪个加载信号归属哪个界面区域。

## 术语

- **列表级加载**：`ScanAgents` 扫描进行中。行集合与顺序本身可能变化。
- **会话级加载**：某个联系人的会话内容正在加载——选中 Agent 的前台绑定/会话加载
  （`conversationSessionLoadingTargets`），或后台浏览预取/刷新
  （`conversationBackgroundRefreshTargets`）。所有加载目标都按目录存在性过滤：
  只有仍无 `conversationSessionsByAgent` 条目的 Agent 才呈现骨架条——首个已提交页
  （含流式读取中的渐进 milestone）即清除骨架，已有目录之上的重载保持静默。
- **加载条**：`MessagingLoadingBar`，一条匿名圆角矩形，高亮从左向右脉冲
  （主题化的 `LicoSkeleton`）。减弱动态时呈现为静态中性条。

## 呈现契约

加载显示在待加载内容所在的位置，而不是全局：

- 会话级加载**只标记该联系人的行**：预览行与活动时间变为加载条。头像、名称、
  标签、未读徽章与活动状态保持真实值——它们已知。右侧会话面板保留自己的转圈，
  为已打开的会话提供反馈；两处指示描述的是不同范围。
- 会话级加载**绝不**升起列表上方的刷新指示条，即使是右侧面板正在转圈的
  选中联系人也一样。
- 列表上方的刷新指示条只在列表级工作时出现——发现扫描——外加下拉手势自身的
  触发进度反馈。
- 行在任何加载状态下都渲染；发现结果与会话目录始终是行的数据源。首页预取进行中的
  Agent 显示加载条直到目录落地；加载失败或为空则回落到诚实的空态。

## 边界

- 本契约只覆盖侧栏行。面板转圈、进度行与发送门禁指示各自跟随自己的状态。
- 已有目录的 Agent 的后台目录热更保持静默：已加载内容绝不在刷新中被骨架替换。
- 骨架度量集中在 `MessagingLoadingBar`；各行不得在调用点重新定制占位样式。
