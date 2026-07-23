# Lico Arc Client Design System

This document describes the implemented visual and interaction system for the
Lico Arc Flutter client. Product scope is controlled by
[`CLIENT-DESKTOP.md`](CLIENT-DESKTOP.md). Theme code and appearance presets under
`apps/desktop/` are authoritative for current tokens and behavior.

## Product Identity

Lico Arc is a lightweight local environment manager for a developer's
machine. It makes local-agent discovery, target-native conversations, local
conversation backup, skill state, Token usage, and encrypted mobile relay
understandable without becoming a new agent framework.

The UI must feel:

1. **Local**: actions should map to visible local targets, config files,
   snapshots, and CLI-backed operations.
2. **Precise**: every write path should show what target, path, field, token
   reference, or snapshot is affected.
3. **Quiet**: the app is an operational tool, not a marketing surface.

## Visual Language — Black Crystal / Cobalt / Signal

The client uses a deliberately restrained color system: **black crystal** for
depth, **cobalt blue** (`#073cfc`) for brand identity and primary actions, and
**signal yellow** (`#fef100`) with **signal orange** (`#ff5d02`) for
highlights, warnings, and destructive or high-attention moments.

This is a dark-first design with high contrast between surface layers and
intentional use of saturated accent colors to guide attention. Very light
tints (such as ice blue) are reserved for luminous effects — glows and
shimmer — and are never used for text or small interactive elements, where
they are hard to distinguish on dark crystal.

### Core Palette

| Role | Value | Name |
| --- | --- | --- |
| App background | `#07070e` | Black Crystal |
| Surface | `#0e0e1a` | Crystal Surface |
| Subtle surface | `#151522` | Crystal Subtle |
| Inset | `#040409` | Crystal Deep |
| Text primary | `#f0eadc` | Warm White |
| Text secondary | `#c4bda8` | Warm Dim |
| Text muted | `#928e82` | Warm Gray |
| Border | `#22223a` | Crystal Edge |
| Border strong | `#34345c` | Crystal Edge Strong |
| Brand accent | `#073cfc` | Cobalt Blue |
| Brand strong | `#5e85ff` | Cobalt Bright |
| Info/interactive text | `#6b8aff` | Cobalt Soft |
| Success | `#34d399` | Crystal Green |
| Warning | `#fef100` | Signal Yellow |
| Danger | `#ff5d02` | Signal Orange |

### Color Hierarchy

1. **Black Crystal** — the foundation. Deep obsidian surfaces create crystalline
   depth through 4 surface layers with meaningful contrast between each step.
2. **Cobalt Blue** — the brand voice. Used for active navigation indicators,
   primary buttons, and brand-identity marks. `#073cfc` stays recognizable on
   dark crystal; the brighter `#5e85ff` and softer `#6b8aff` carry hover
   states, focus rings, and interactive text labels.
3. **Signal Yellow & Orange** — the attention pair. Yellow marks highlights
   and warning states; orange marks destructive actions and moments that need
   immediate attention. Ice blue survives only as an effect color (glow,
   shimmer), never as content.

### Light Mode (when user prefers light)

For users who prefer light mode, the client falls back to the `geek-light-blue`
preset. The crystal obsidian palette is the brand-default dark experience.

### Theme Implementation

The Flutter client builds `ThemeData` from appearance preset tokens via
`LicoThemeColors` (see `lib/src/frontend/shared/ui/theme.dart`). The
`lico-crystal` preset is the default dark theme.

Key mapping:
- `background` ← `bg-base` (#07070e)
- `surface` ← `bg-surface` (#0e0e1a)
- `surfaceLow` ← `bg-subtle` (#151522)
- `text` ← `text-primary` (#f0eadc)
- `textMuted` ← `text-muted` (#928e82)
- `primary` ← `brand` (#073cfc)
- `primaryStrong` ← `brand-strong` (#5e85ff)
- `info` ← `info` (#6b8aff)
- `textOnPrimary` ← `text-on-brand` (#ffffff)

## Navigation

Desktop first-level destinations live in a **left icon rail** that rests
directly on the window background — no rail card, no labels, no collapse
chrome. The rail, the transparent top band, and the window background form
the shell's lowest layer; the macOS traffic lights overlay the rail's top
clearance. The top band's leading edge carries the active destination
title; its trailing edge carries the search capsule, whose radius and
insets stay concentric with `windowCornerRadius`.

Default desktop destinations:

- Agents
- Token Usage
- Skill Hub
- Mobile Relay
- Settings

Agent conversations and local conversation backup remain inside Agents. Protocol
adapters are implementation foundations rather than standalone destinations.
Global search may jump to any current destination.

Content stacks in **three flat layers**: the background layer above, one
workspace container card standing off the window's trailing and bottom
edges (one quiet tonal step up), and the destination detail as the third,
lightest layer. In Agents the conversation list stays transparent so it
reads as the container's own surface, while the conversation detail nests
inside the container as its own rounded card with a distinct tone.

Mobile keeps a compact Agents/Settings shell; pairing and encrypted relay flows
open contextually from the agent experience.

## Typography

Use system fonts for a native desktop feel. Use monospace text only for paths,
commands, JSON snippets, token environment variable names, and target-native
configuration fields.

- Body text: system sans-serif, 14px, linen color
- Headings: system sans-serif, light to normal weight
- Code/paths: monospace, soft cobalt (#6b8aff) for emphasis or warm gray for subdued

## Surface & Depth

Depth in the client uses crystalline layering with meaningful contrast
between each step:

1. **Window/scaffold**: `#07070e` (black crystal base)
2. **Panels/cards**: `#0e0e1a` (crystal surface)
3. **Hover/selected**: `#151522` (crystal subtle)
4. **Inset/code**: `#040409` (crystal deep)

Card borders use 1px at `colors.line.withAlpha(80)` for subtlety.
Hover states show cobalt-tinted border `colors.primary.withAlpha(50)`
with soft box shadow for depth. Action labels use soft cobalt (#6b8aff)
to invite interaction.

## Buttons & Actions

- Primary: solid cobalt blue with white text
- Secondary: transparent with subtle cobalt border
- Destructive: signal orange border or fill when confirmed
- Disabled: reduced opacity, `#54514a` text

## Module Guidance

### Agents

Show supported targets, detection confidence, binary/config paths, manual add
entries, and pairing state. Scanning is conservative and must not imply that
the client launched or authorized an agent.

Desktop Agents spans the shell's upper two layers (top band unchanged):

1. **Workspace container card** fills the content area as the second
   layer. The conversation list inside it stays transparent, reading as
   the container's own surface; a single header row hosts the section
   label and the archive, new-conversation, and add-target actions, and
   the tree below groups conversations by agent, then by project.
2. **Conversation detail** nests inside the container as its own rounded
   card on the lightest tone, inset from the container's top, trailing,
   and bottom edges. Selecting a list entry shows the conversation in
   that card. One icon-button recipe (`ConversationIconButton`) carries
   every header, list, and composer action so the surface stays aligned
   and consistent; the composer embeds its send control inside the input
   capsule, and a send gate reads as one slim notice line instead of a
   banner card.
3. **Agent discovery** is incremental: last-scan results are cached and painted
   immediately; each packaged adapter is probed by its own concurrent
   `targets inspect` process, and each hit is upserted into the sidebar as soon
   as that probe returns (known cached agents are not re-probed on quiet
   bootstrap).

The current packaged target projection is Antigravity, Claude Code, Codex,
Cursor, Copilot, Hermes, Kilo Code, Kimi Code, OpenClaw, OpenCode, and Pi. The
packaging registry remains the authority; this visual snapshot does not imply
conversation readiness.

#### Native Conversation and Process Disclosure

The conversation surface must preserve the selected native session instead of
creating an Arc-local lookalike. Readiness is fail closed: the current
reducer-owned state is `0 ready / 0 failed / 2 blocked / 9 unverified`
(`sendEnabled: 0` across eleven adapters), so a normal release composer is not
shown for any target. Antigravity is blocked by
`antigravity_cli_structured_transport_unavailable`; Cursor by
`safe_cleanup_unavailable`. Claude Code, Kimi Code, Pi, and the remaining
adapters are `unverified` with `evidence_missing` until reducer-owned live
parity evidence lands. Detection and history remain visually distinct from
permission to send.

A contiguous run of native reasoning, metadata, progress, tool calls, tool
results, and errors is rendered as one process item, never as a vertical stack
of per-event cards. Its default state is collapsed and quiet: one summary row,
status, optional duration/count, and a clear expansion affordance. Activating
the row by pointer, touch, Enter, Space, or accessibility action expands the
same item in place into ordered, flat operation rows. Expansion must not remove
the item, replace it with blank space, move its toggle out of reach, or reset
because a later message arrives. A second activation collapses it.

Expanded rows use the same surface rather than nested cards. They may show a
sanitized operation label, lifecycle state, safe result summary, and an
explicit provider-authored reasoning summary. They must not show raw
chain-of-thought, tool arguments, opaque metadata, credentials, native session
identifiers, or local paths. Unknown structured event types fail closed to a
safe generic row instead of falling back to assistant prose. The collapsed and
expanded states share the same redacted semantics label.

Acceptance uses the current release `.app` for three consecutive paired runs;
every run covers native-create/Arc-resume and Arc-create/native-resume. It checks
the real native session id, cwd and effective settings, ordered
event/tool/error projection, final result and isolated side effects, keyboard
and screen-reader activation, bounded output, cleanup on success and failure,
and argv/log/evidence privacy.

#### Conversation attention and refresh scheduling

Conversation refresh priority is determined jointly by window focus,
application lifecycle, the currently visible module, and the active agent and
session. Activating the conversation surface, resuming or refocusing the app,
switching the active agent or session, and sending a message all trigger an
immediate refresh. While that conversation remains visible and active, it uses
the shortest refresh interval.

Non-active conversations refresh at a lower frequency. Equivalent refresh
requests are coalesced and deduplicated instead of competing for the same
resource, and polling pauses while the app is hidden. Background work must
never block the active conversation or change the user's selection, input,
scroll position, or expanded process items.

Refresh results publish state only when the conversation has changed
semantically. Notifications are scoped to the state slice that changed so that
unrelated modules, inactive conversations, and stable portions of the active
conversation are not rebuilt.

### Skill Hub

Present local skills by agent with source, installed version, integrity state,
and time-window usage count. Updates require an explicit mirror or GitHub
source and a direct user action. Deletion always names the selected agent or
agents and presents the exact scope before confirmation.

### Mobile Relay

Mobile Relay focuses on pairing and gateway choice. Diagnostic protocol state
stays hidden unless it is needed to unblock pairing.

### Settings

Settings covers known paths, manual binaries, portable data root, server
profile, client preferences, archive settings, and a single client log export
button. It should not render raw activity logs or become a registry for server
business modules.

## Accessibility

- Text contrast: warm white (#f0eadc) on black crystal (#07070e) achieves
  ~16:1 (exceeds WCAG AAA); white on cobalt blue (#073cfc) achieves ~6.8:1.
- All command buttons, lists, and dialogs must be keyboard navigable.
- Icon-only controls require tooltips.
- Readiness states such as ready, blocked, and unverified require visible text
  labels and cannot rely on color alone.
- Long paths, command output, and config previews must wrap or scroll without
  obscuring adjacent controls.
