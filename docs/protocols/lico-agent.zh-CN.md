# Lico Agent

[English](lico-agent.md) · 简体中文

权威实现：`domain/lico_agent/`、`platform/lico_agent_driver/`、
`platform/process_sandbox/`，以及同级二进制 `lico-agent`。实现或验证变更时
同步更新本文。

Lico Agent 是 LicoUp **自研**运行时，在智能体列表中作为普通一项
（`lico-agent`），与 Pi、Codex 等第三方适配器同级。它**不是**顶部「Lico」
群聊入口本身。

## 能力

- Stdio JSONL RPC（`lico-agent-rpc-stdio-jsonl`）：`get_state`、`prompt`、
  `steer`、`abort`。
- 模型仅经本地回环 [LLM Gateway](llm-gateway.zh-CN.md)；非回环地址失败关闭。
- 配置档：`base` 与继承模式 `plan`（仅 `read` + `write_plan`）。
- Plan 模式在 macOS seatbelt 能力
  `platform-lico-agent-plan-isolated-v1` 下拉起：写权限仅限一个绝对路径计划
  文件；出站网络仅限 Gateway 端口。非 macOS 上 Plan 失败关闭。
- 会话状态由父进程保存在 `{portable}/client-state/lico-agent/`；子进程不落盘
  会话库。

## 与「Lico」群聊入口的关系

联系人 **Lico**（原「默认」）打开 LicoUp 自有**群聊 Conversation**。适应性
飞轮选择参与智能体（可包含 Lico Agent）。默认发言权为飞轮主智能体调度、对等
气泡呈现。Composer 中飞轮悬停选择器与圆形编辑按钮见 USER-GUIDE 投影。
