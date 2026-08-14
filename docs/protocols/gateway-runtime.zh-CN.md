# LicoUp Gateway Runtime

[English（规范版本）](gateway-runtime.md) · 简体中文（本地化）

Gateway Runtime 是单一本机进程（`lico-gateway`），包含两层：

1. **LLM Gateway**（下层）— 回环 HTTP 模型协议路由与凭证交接。见
   [`llm-gateway.zh-CN.md`](llm-gateway.zh-CN.md)。
2. **Communication Channel**（上层）— 把外部聊天面接入本机智能体会话的消息
   适配层。Telegram 是第一个 channel。

## 进程

- 二进制：`lico-gateway`（遗留名 `lico-llm-gateway` 仍运行同一运行时）。
- 生命周期 CLI：`gateway service {status,start,stop,initialize}`，以及别名
  `llm-gateway service …`。
- 清单 CLI：`gateway inventory reload --stdin-json true` 只做 **局部** 热加载：
  更新已验收 conversation readiness（LLM gateway 状态目录下的私有
  `inventory.sock` + 持久 overlay）。新 ready 的智能体会进入 `/agent` 准入；
  绝不因清单变更重启 Gateway，也绝不清理 Telegram 绑定、已绑定 `session_id`
  或进行中的 turn。控制套接字不可用时仅写入 overlay（`mode: overlay_pending`），
  运行中进程保持不动。
- Channel CLI：`gateway channel status`，
  `gateway channel telegram credentials|pairing …`。
- Channel 故障不得停止 LLM 回环监听。

## Telegram channel

- 传输：默认 Telegram Bot API long polling。
- 准入：私聊 pairing；批准后会话级委托。
- 控制：`/start`、`/pair`、`/unpair`、`/whoami`、`/status`、`/agent`、
  `/session`、`/new`、`/reset`、`/stop`、`/help`、`/commands`（别名：`/id`、
  `/agents`、`/sessions`、`/revoke`）。
- 入站：文本、caption、图片/文档/视频/动画/语音/音频/贴纸/圆视频、位置/
  场所/联系人/投票、引用回复、转发，以及 `edited_message`；归一化为带媒体
  占位符的智能体信封；斜杠命令从 text 或 caption 解析。
- 桥接：已配对普通内容 → `conversation_lane` send → `sendMessage` 回写
  （回复挂到触发消息）。
- 智能体准入：`/agent` 仅列出并绑定 conversation readiness 为 `ready` 且已
  检测到可执行文件的智能体；未验收库存不会出现在通道上。verified 状态变更
  （parity reducer `--write`）时，主机对运行中 Gateway 做局部热加载：新 ready
  智能体出现在 `/agent`，已绑定聊天保留其智能体与会话。
- 状态文件仍在 portable 的 `telegram-gateway/` 目录；产品名是 Telegram
  Communication Channel，不是独立网关。

## 状态模式

`gateway service status` 在 `licoup.gateway-runtime.v1` 下报告 `layers.llm` 与
`layers.channels`。清单与 status 永不返回 bot token 或模型 API key。
