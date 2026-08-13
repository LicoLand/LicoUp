# Lico Agent

English (normative) · [简体中文](lico-agent.zh-CN.md)

Authority: `domain/lico_agent/`, `platform/lico_agent_driver/`,
`platform/process_sandbox/`, and the `lico-agent` sibling binary. Update this
projection when those implementations or their verification change.

Lico Agent is a **first-party** LicoUp-owned runtime. It appears in the agent
list as one ordinary option (`lico-agent`), peer to third-party adapters such as
Pi or Codex. It is **not** the top「Lico」group Conversation entry.

## Capabilities

- Stdio JSONL RPC (`lico-agent-rpc-stdio-jsonl`): `get_state`, `prompt`,
  `steer`, `abort`.
- Models only through the local loopback [LLM Gateway](llm-gateway.md).
  Non-loopback base URLs fail closed.
- Profiles: `base` (read + optional future write tools) and `plan`
  (inheritance mode: `read` + `write_plan` only).
- Plan mode spawns under macOS seatbelt capability
  `platform-lico-agent-plan-isolated-v1`: filesystem write is limited to one
  absolute literal plan file
  (`{portable}/client-state/plans/active-plan.md` by default); network outbound
  is limited to the Gateway port. Non-macOS Plan mode fails closed.
- Session/transcript state is parent-owned under
  `{portable}/client-state/lico-agent/`. The child process does not persist
  its own session store.

## Relation to the「Lico」group entry

The messaging contact labeled **Lico** (formerly Default) opens a LicoUp-owned
**group Conversation**. Adaptive Flywheel selects which agents—including Lico
Agent—participate. Group turn-taking defaults to Flywheel main dispatch with
peer bubbles. See the desktop USER-GUIDE projection for the composer Flywheel
hover picker and circular edit control.
