# LicoUp 下属智能体 MCP

[English（规范版本）](subagent-mcp.md) · 简体中文（本地化） · [架构](../architecture/README.zh-CN.md)

权威实现：`crates/licoup-native/src/bin/lico-subagent-mcp.rs`、
`domain/delivery_workflow.rs` 与 `platform/delivery_workflow_runtime.rs`。
本文档描述当前原生交付契约，不定义第二个调度器。

## 交付生命周期

MCP 只是薄调用面。交付仅暴露四个操作：

- `lico_delivery_start` 创建或恢复持久化 Plan。
- `lico_delivery_authorize` 授权当前 Plan 摘要。
- `lico_delivery_status` 读取持久化状态和 Plan 的下一动作。
- `lico_delivery_cancel` 显式取消工作流，并把取消请求转给活动原生对话。

调用方不能提交 frontier、绑定 Worker、选择 route、接受 Task 或打开 Reviewer。
原生调度器从当前 `DeliveryPlanEngine` 获取完整 eligible frontier，按稳定顺序排列，
再通过有界原生通道派发。不同工作流可以并发；同一工作流、Task attempt 与原生会话
保持有序。等待终态事件不占用消息通道。

每次派发都按以下持久化顺序进行：

1. 适应性飞轮选择角色与难度 route。
2. LicoUp 冻结 agent、model、reasoning effort 与 route authority receipt。
3. workflow ledger 记录 token baseline 与对话绑定。
4. 通过原生通道发送准确 Plan brief 和已准入的原生对话位置。
5. 只有确定的终态事件才结算用量；沉默或耗时仍保持 pending。
6. 终态回调幂等执行，并只推进一次 Plan checkpoint。

Plan 与 Checkpoints 是唯一生命周期权威。插件是否就绪只影响适配器准备，不会改变
交付归属、eligible frontier 或 route 选择。

## 直接一次性操作

`lico_subagents_list`、`lico_subagent_delegate`、`lico_subagent_continue` 和
`lico_subagent_cancel` 仅用于非交付的一次性下属回合。它们不会创建交付角色、Plan
checkpoint，也不会形成第二个交付调度器。续接必须使用目录准入步骤产生的准确原生
对话位置。

## 对话准入

每个交付对话都必须通过原生目标暴露的准确目录条目准入。位置必须是 canonical、绝对、
有界、位于目录条目内，并且不能是文件系统根目录、home 目录或客户端工作区。相对、
缺失、越界、歧义和无界位置分别返回不同的派发前错误；没有继承或相对工作目录兜底。

交接中唯一携带上下文的值是已准入的原生对话位置。Brief 只包含稳定控制事实、仓库
相对引用和原生位置引用，不包含下属输出或生成摘要。

## Receipt 与失败

公开 receipt 不携带路径和正文，只暴露 schema 或 operation、有限标识、stage、component、
retryability、recovery action 以及安全生命周期状态。原始命令、prompt、reply、路径、
runtime 行和异常都保持私有。不确定的原生效果报告为 `in_doubt`，重试前必须 reconcile
准确对话。某一派发分支出现有类型终态失败时，无关分支继续执行。

交付归属始终是 `licoup`，route 选择始终是 `adaptive-flywheel`。两者与可选适配器插件
是否就绪相互独立。

## 有界契约

| 边界 | 上限 |
| --- | --- |
| MCP 输入帧 | 64 KiB |
| Brief 或一次性 prompt | 48 KiB |
| 对话位置 | 4 KiB |
| 工作目录 | 4 KiB |
| MCP 工作线程 | 8 |
| 待处理工具调用 | 32 |

原生调度器在发送前持久化 dispatch intent。重启恢复会 reconcile 任意 pending 对话，
不会创建重复派发。
