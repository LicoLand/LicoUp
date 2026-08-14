# LicoUp Gateway Runtime

English (normative) · [简体中文](gateway-runtime.zh-CN.md)

The Gateway Runtime is one local process (`lico-gateway`) with two layers:

1. **LLM Gateway** (lower) — loopback HTTP model-protocol routing and credential
   handoff. See [`llm-gateway.md`](llm-gateway.md).
2. **Communication Channel** (upper) — messaging adapters that admit external
   chat surfaces into local Agent conversations. Telegram is the first channel.

## Process

- Binary: `lico-gateway` (legacy name `lico-llm-gateway` still runs the same
  runtime).
- Lifecycle CLI: `gateway service {status,start,stop,initialize}` and the alias
  `llm-gateway service …`.
- Inventory CLI: `gateway inventory reload --stdin-json true` performs a
  **partial** hot-reload of verified conversation readiness only (private
  `inventory.sock` under the LLM gateway state directory, plus a persisted
  overlay). Newly ready agents become admissible for `/agent`. The Gateway
  process is never restarted for inventory changes, and Telegram bindings,
  bound `session_id`s, and in-flight turns are never cleared. When the control
  socket is unavailable, the overlay is written for the next start
  (`mode: overlay_pending`) and the running process is left untouched.
- Channel CLI: `gateway channel status`,
  `gateway channel telegram credentials|pairing …`.
- Channel failures must not stop the LLM loopback listener.

## Telegram channel

- Transport: Telegram Bot API long polling (default).
- Access: DM pairing; session-level delegation after approval.
- Control: `/start`, `/pair`, `/unpair`, `/whoami`, `/status`, `/agent`,
  `/session`, `/new`, `/reset`, `/stop`, `/help`, `/commands` (aliases:
  `/id`, `/agents`, `/sessions`, `/revoke`).
- Inbound: text, captions, photo/document/video/animation/voice/audio/sticker/
  video_note, location/venue/contact/poll, reply quotes, forwards, and
  `edited_message`, normalized into an agent-facing envelope with media
  placeholders; slash commands parse from text or caption.
- Bridge: paired ordinary content → `conversation_lane` send → `sendMessage`
  reply (threaded to the triggering message).
- Agent admission: `/agent` lists and binds only agents with conversation
  readiness `ready` and a detected local executable. Unverified inventory is
  not offered on the channel. When verified readiness changes (parity reducer
  `--write`), the host automatically partial-hot-reloads that document into a
  running Gateway so newly ready agents appear in `/agent` while already-bound
  chats keep their agent and conversation session.
- State files remain under the portable `telegram-gateway/` directory; the
  product name is the Telegram Communication Channel, not a separate gateway.

## Status schema

`gateway service status` reports `layers.llm` and `layers.channels` under
schema `licoup.gateway-runtime.v1`. Inventory and status never return bot tokens
or model API keys.
