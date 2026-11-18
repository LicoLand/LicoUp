# Conversation profiles

| Relationship | Authority |
| --- | --- |
| Product scope | [Client functionality](CLIENT-DESKTOP.md) |
| Profile contract | `contracts/conversation_profile.dart` |
| Persistence port | `frontend/shared/messaging/conversation_profile_store.dart` |
| Registry | `frontend/shared/messaging/conversation_profile_registry.dart` |
| Creation dialog | `frontend/features/agents/ui/conversation/conversation_profile_create_dialog.dart` |
| Native intent | `licoup-conversation` `ProfileIntent`, `DirectTurnExecutionContext` |

This document owns the conversation-profile feature contract — what a
Profile is, how it is created, and how its preferences reach dispatch.

## Terms

- **Conversation profile** (`ConversationProfile`): a persistent persona
  built on one local Agent's capabilities. It carries a display name, a
  mascot avatar, a backing Agent, a model, a reasoning effort, and advanced
  preferences (permission mode, working directory, context window, default
  instructions). Its stable principal is `profile:<id>` — distinct from the
  backing Agent's `agent:<agentId>` identity.
- **Direct conversation**: a canonical conversation created with
  `isGroup=false` that holds the profile membership. It appears in the
  contact list as a persona row and is excluded from group surfaces.
- **Profile intent**: `ProfileIntent` fields persisted per membership —
  `preferredModel`, `preferredReasoningEffort`, `preferredPermissionMode`,
  `preferredEnvironment`, `preferredInstructions`, `preferredContextWindow`.
  Native dispatch applies them when the profile is admitted to a turn.

## Lifecycle

1. The messaging `+` menu offers **创建智能体 / Create Agent** beside the
   existing conversation and group actions.
2. The creation dialog collects: a mascot avatar (random pre-selection),
   a display name, and the Agent → model → reasoning-effort cascade driven
   by real adapter catalogs. Advanced options are collapsed by default:
   context window, working directory, default instructions, and the
   permission-mode selector — rendered only when the selected Agent
   declares permission modes; options are never invented.
3. `CreateConversationProfile` → `createProfileConversation` runs
   `conversation.create` (`isGroup=false`, human owner + `profile:<id>`
   member), sets the profile as the assistant, then writes the profile
   intent. Success registers the profile, links `conversationId`, and
   emits `ConversationProfileCreated`.
4. The profile persists in `client-state/conversation-profiles.json`
   (schema version 1). Hydration runs once at composition startup, skips
   malformed entries, and is suppressed from triggering a write-back.

## Surfaces

- The contact list renders a profile row — mascot avatar, profile name,
  preview, timestamp, unread badge, row-level loading skeleton — inside the
  Agents filter, sorted with existing rows.
- The group-creation dialog lists profiles as selectable members; a
  profile joins with its `profile:<id>` principal and receives its
  persisted intent after creation, keeping the backing Agent's own
  membership distinct.
- Selecting the profile row opens its direct conversation through the
  canonical conversation pane; messages without an @-mention dispatch to
  the profile because it is the conversation assistant.

## Dispatch application

`apply_admitted_runtime_fields` maps the persisted intent into dispatch
parameters on every admitted path — regular direct turns, continuity
turns, and the stdio RPC direct-turn path. `preferredInstructions` enters
turn guidance after the assistant's private instructions and before the
member-role block; `preferredContextWindow` is forwarded as the
`contextWindow` dispatch parameter. Whether a given runtime adapter acts
on `contextWindow` is the adapter's own contract.

## Boundaries

- A profile is client-side persona data; it grants no extra agent
  capabilities beyond what the selected Agent declares.
- A profile with no direct conversation yet still lists in the group
  member picker — membership creation is independent of the contact row.
- There is no profile deletion surface yet; records persist until that
  lifecycle is designed.
