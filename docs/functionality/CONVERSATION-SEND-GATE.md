# Conversation send gate

| Relationship | Authority |
| --- | --- |
| Product scope | [Client functionality](CLIENT-DESKTOP.md) |
| Visual language | [Design system](DESIGN-SYSTEM.md) |
| Unread and row-click contract | [Messaging unread navigation](MESSAGING-UNREAD-NAVIGATION.md) |
| Gate row rendering | `frontend/features/agents/ui/agent_conversation_pane/` |
| Gate reason codes | `contracts/target_candidate.dart` |

This document owns the interaction contract for the conversation send gate —
the row above the composer that reports why sending is unavailable, and the
loading affordance that replaces it while availability is still being
resolved.

## Terms

- **Runtime-binding gate codes**: `native_agent_executable_not_detected`,
  `native_agent_runtime_profile_unavailable`, and
  `runtime_message_send_unavailable`. These describe the local executable or
  runtime profile the scan and the selection-time binding resolve; the
  rescan action is their remedy.
- **Resolving**: a `ScanAgents` pass or the selection-time executable binding
  (`native.phase == loading`) is still in flight. Gate state observed during
  this window is provisional.
- **Contact list membership**: the messaging sidebar renders exactly the
  targets discovery produces (`isConversationAgent` over the scanned
  `TargetCandidate` list plus each agent's session catalog). Rows are never
  hardcoded — an agent appears only because the scan found it present on the
  host.

## Rendering contract

A listed agent was already discovered — for it, "not detected" can never be
a final verdict, only a provisional scan state. Therefore:

- While a gate reason in the runtime-binding family is **resolving**, the
  gate area renders a loading affordance (a small progress indicator with a
  muted "checking the local runtime" label). No warning icon, no verdict
  text, no action button.
- Once the scan and binding **settle** and the code is still reported, the
  honest unavailable row renders: the localized reason plus the rescan
  action. A genuinely absent executable stays explainable — the loading
  affordance is a state, never a permanent stand-in.
- Gate codes outside the runtime-binding family (for example
  `antigravity_auth_required` or `virtual_machine_connection_invalid`) are
  never provisional: they render their usual row immediately, even while a
  scan runs.

## Boundaries

- The contract covers the send-gate row only. A failed send keeps the
  separate send-failure row with its verbatim reason.
- Resolving state is derived from the existing scan and catalog-loading
  signals; the gate introduces no additional scanning of its own.
- The discovery-driven list rule is a property statement, not a visual
  state: sidebar rows must continue to come from scanned targets and loaded
  session catalogs, never from a fixed product list.
