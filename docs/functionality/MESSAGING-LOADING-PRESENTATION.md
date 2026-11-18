# Messaging loading presentation

| Relationship | Authority |
| --- | --- |
| Product scope | [Client functionality](CLIENT-DESKTOP.md) |
| Visual language | [Design system](DESIGN-SYSTEM.md) |
| Unread and row-click contract | [Messaging unread navigation](MESSAGING-UNREAD-NAVIGATION.md) |
| Loading bar component | `frontend/shared/messaging/messaging_loading_bar.dart` |
| Skeleton animation | `frontend/shared/ui/lico_skeleton.dart` |
| Row rendering | `frontend/features/agents/ui/messaging/messaging_contact_list.dart` |

This document owns the loading-presentation contract for the messaging
conversation list — which loading signal belongs to which surface.

## Terms

- **List-level loading**: an agent discovery scan (`ScanAgents`) is in flight.
  The set and order of rows themselves may change.
- **Conversation-level loading**: one contact's conversation content is
  loading — the selected agent's foreground bind/session load
  (`conversationSessionLoadingTargets`) or a background browse
  prefetch/refresh (`conversationBackgroundRefreshTargets`). Every loading
  target is filtered through catalog presence: only an agent that still has
  no `conversationSessionsByAgent` entry earns skeleton bars, so the first
  committed page — including a progressive milestone mid-stream — clears them
  and a reload over an existing catalog stays silent.
- **Loading bar**: `MessagingLoadingBar`, an anonymous rounded rectangle that
  pulses a highlight leading→trailing (a themed `LicoSkeleton`). Reduced
  motion renders it as a static neutral bar.

## Rendering contract

Loading is displayed where the pending content lives, not globally:

- A conversation-level load marks **only that contact's row**: the preview
  line and the activity timestamp become loading bars. The avatar, name, tag,
  unread badge, and activity status keep their real values — they are already
  known. The right conversation pane keeps its own spinner for the opened
  conversation; the two affordances describe different scopes.
- A conversation-level load **never** raises the list-level refresh
  indicator above the list, even for the selected contact whose pane is
  spinning.
- The list-level refresh indicator appears only for list-level work — a
  discovery scan — plus the pull gesture's own armed progress feedback.
- Rows render regardless of load state; discovery output and session
  catalogs stay the row source. An agent whose first-page prefetch is in
  flight shows bars until its catalog lands, then falls back to the honest
  empty state if the load fails or returns nothing.

## Boundaries

- The contract covers the sidebar rows. The pane's spinner, progress rows,
  and gate affordance follow their own states.
- Background catalog warm for an agent that already has a catalog stays
  silent: loaded content is never replaced by skeletons mid-refresh.
- Skeleton metrics live in `MessagingLoadingBar`; rows must not restyle the
  placeholder per call site.
