# Messaging unread navigation

| Relationship | Authority |
| --- | --- |
| Product scope | [Client functionality](CLIENT-DESKTOP.md) |
| Visual language | [Design system](DESIGN-SYSTEM.md) |
| Behavior-state coverage | [UI interaction state machine](UI-INTERACTIONS.md) |
| Row rendering and read cursors | `frontend/features/agents/ui/messaging/` |

This document owns the interaction contract for unread conversations in the
messaging contact list. It describes what a click on a contact row does when
that contact has unread messages, in what order sessions are visited, and when
a conversation counts as read.

## Terms

- **Contact**: one row in the messaging list that represents an agent product
  (merged targets share one row). Canonical group rows are conversations, not
  contacts; they keep their own single-conversation behavior.
- **Unread**: a session or group conversation whose durable read cursor sits
  below its current message count. Cursors persist locally; a conversation
  that has never been opened counts as unread in full once the durable store
  has been loaded — unless the coverage baseline adopts it (below).
- **Coverage baseline**: the instant the durable cursor document started
  accounting for conversations (`baselineAtUnixMs` in the document; for
  documents written before per-session coverage existed, the file's own
  modification time). A conversation whose last activity predates the
  baseline is pre-existing history: it is adopted read at its current count
  on first sight and the adoption persists. A conversation with activity
  after the baseline is genuinely new and badges its full count.
- **Unread session**: a contact's session with unread count greater than zero.
  Sub-agent threads never count separately; they belong to their parent
  conversation.

## Row badge

A contact row's badge shows the **total unread message count across all of the
contact's sessions**, not only the newest session. The badge disappears only
when every session of the contact is read. Group rows show the unread count of
their single conversation.

## Click contract

Clicking a contact row resolves its sessions in most-recent-first order and
opens the **first session that still has unread messages**. Opening marks that
session read: its cursor advances to the current count and its contribution to
the badge clears.

Because the just-opened session is already read, the next click on the same
row finds the **next most recent session that still has unread** and opens it.
Each additional click repeats this: the row always leads to the newest
remaining unread session. No explicit cycle index is kept — the ordering is
recomputed at click time, so a session that regains unread (a new message
arrives) is picked up again by the same rule.

When no session of the contact has unread left, the click falls back to the
default behavior: it opens the contact's most recent conversation (or the new
conversation draft when none exists). This is the terminal state of the cycle —
"until all messages are read" is reached when the fallback runs.

The same contract applies to the collapsed avatar-column presentation.

## Read semantics

- Opening a conversation — whether by row click, session intent, or restore —
  marks it read immediately; the cursor never waits for a message to scroll
  into view.
- While a session is open it stays read: when its message count grows, the
  cursor follows. A selected conversation can never badge.
- The "still open" mark follows the **actually selected session**, not the
  contact's newest session. An older session open in the pane does not clear
  the unread state of newer sessions that were never opened.
- Switching away does not mark the previously open conversation "unread";
  cursors only move forward.
- Adopting a pre-baseline conversation writes its current count once, so
  messages that arrive afterwards badge as a normal delta. Saving a cursor
  document never widens the baseline: the stored instant belongs to the
  document being replaced, not to the save.

## Boundaries

- Unread bookkeeping covers sessions present in the loaded catalog page.
  Sessions outside the loaded page cannot badge and are not visited by the
  cycle until the catalog loads them.
- Group conversation rows keep the existing single-conversation semantics:
  click opens the group and marks it read; there is nothing to cycle.
- Read cursors are local durable state. They are not synchronized to other
  devices and are not an agent-visible read receipt.
