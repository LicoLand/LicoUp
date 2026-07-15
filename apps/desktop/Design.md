# Lico Arc Client Design System

This document describes the visual and interaction direction for the Lico Arc
Flutter desktop client. Product scope is controlled by
[`docs/functionality/CLIENT-DESKTOP.md`](../../docs/functionality/CLIENT-DESKTOP.md).

## Product Identity

Lico Arc is a lightweight local environment manager for a developer's
machine. It makes target-native conversations and history, readiness state,
MCP configuration, local Skill Hub state, and configuration recovery
understandable without becoming a new agent framework.

The UI must feel:

1. **Local**: actions should map to visible local targets, config files,
   snapshots, and CLI-backed operations.
2. **Precise**: every write path should show what target, path, field, token
   reference, or snapshot is affected.
3. **Quiet**: the app is an operational tool, not a marketing surface or a
   server console clone.

The client must not present removed Console, Mail, DataConnector, upload queue,
Knowledge Graph, or server API panels as first-class product surfaces.

## Visual Language — Black Crystal / Golden / Ice Blue

The client uses a deliberately restrained three-color system: **black crystal**
for depth, **golden radiance** for brand identity and primary actions, and
**ice blue** for informational highlights and secondary interactions.

This is a dark-first design with high contrast between surface layers and
intentional use of luminous accent colors to guide attention.

### Core Palette

| Role | Value | Name |
| --- | --- | --- |
| App background | `#07070e` | Black Crystal |
| Surface | `#0e0e1a` | Crystal Surface |
| Subtle surface | `#151522` | Crystal Subtle |
| Inset | `#040409` | Crystal Deep |
| Text primary | `#f0eadc` | Warm White |
| Text secondary | `#c4bda8` | Warm Dim |
| Text muted | `#7e94b0` | Slate |
| Border | `#22223a` | Crystal Edge |
| Brand accent | `#d4a853` | Golden Radiance |
| Brand strong | `#f5d47a` | Gold Bright |
| Info/technical | `#5ecfff` | Ice Blue |
| Success | `#6ee8a8` | Crystal Green |
| Warning | `#f5d47a` | Gold Bright (shared with brand strong) |
| Danger | `#f57070` | Crystal Red |

### Three-Color Hierarchy

1. **Black Crystal** — the foundation. Deep obsidian surfaces create crystalline
   depth through 4 surface layers with meaningful contrast between each step.
2. **Golden Radiance** — the brand voice. Used for active navigation indicators,
   primary buttons, and brand-identity marks. Draws the eye to important actions.
3. **Ice Blue** — the guide. Used for informational cues, hover states on
   secondary items, action labels, search icons, and technical data. Provides
   a cool counterpoint to the warm gold and helps users discover functionality.

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
- `textMuted` ← `text-muted` (#7e94b0)
- `primary` ← `brand` (#e0b24a)
- `primaryStrong` ← `brand-strong` (#ffd666)
- `info` ← `info` (#5ecfff)
- `textOnPrimary` ← `text-on-brand` (#07070e)

## Navigation

Desktop first-level destinations live in the **top bar** as flat icon buttons
(after the macOS traffic-light safe inset). There is no left icon rail.

Default desktop destinations:

- Home (control panel)
- Agents

Plugins, Skill Hub, and Token Usage are reached from the Agents left sidebar
(Explore-style upper nav). Global search can still jump to those sections.

Trailing tools (right): **Pairing** · **More** (Settings / Runtime) · `|` ·
**Avatar**. Settings and Runtime are reached from the more menu; pairing opens
Mobile Relay.

A VS Code–style **centered** search field spans the visual center of the full
top bar (including traffic-light width in the centering calculation). Its
corner radius matches `windowCornerRadius` so the field curvature stays
consistent with the window chrome.

Mobile keeps its separate bottom navigation.

## Typography

Use system fonts for a native desktop feel. Use monospace text only for paths,
commands, JSON snippets, token environment variable names, and target-native
configuration fields.

- Body text: system sans-serif, 14px, linen color
- Headings: system sans-serif, light to normal weight
- Code/paths: monospace, ice-blue (#5ecfff) for emphasis or slate for subdued

## Surface & Depth

Depth in the client uses crystalline layering with meaningful contrast
between each step:

1. **Window/scaffold**: `#07070e` (black crystal base)
2. **Panels/cards**: `#0e0e1a` (crystal surface)
3. **Hover/selected**: `#151522` (crystal subtle)
4. **Inset/code**: `#040409` (crystal deep)

Card borders use 1px at `colors.line.withAlpha(80)` for subtlety.
Hover states show gold-tinted border `colors.primary.withAlpha(50)`
with soft box shadow for depth. Action labels use ice blue to
invite interaction.

## Buttons & Actions

- Primary: gold gradient or solid gold with dark text
- Secondary: transparent with subtle gold border
- Destructive: crystal red border or fill when confirmed
- Disabled: reduced opacity, `#4a4a64` text

## Module Guidance

### Agents

Show supported targets, detection confidence, binary/config paths, manual add
entries, and pairing state. Scanning is conservative and must not imply that
the client launched or authorized an agent.

Desktop Agents uses a **sidebar-as-background + floating conversation card**
layout (top system bar unchanged):

1. **Left rail** sits on the window background (no solid panel chrome). Upper
   Explore-style nav hosts Plugins, Skill Hub, and Token Usage; the lower tree
   groups conversations by agent, then by project (working directory).
2. **Right card** is an elevated surface (≈16px radius, soft shadow, inset from
   the shell edges). Selecting a sidebar destination shows conversation detail,
   MCP plugins, skills, or usage stats in that card.
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

### MCP Plugins

Treat LicoLite MCP as a peer plugin. Show target-native MCP fields, version/status
when available, update/repair triggers, and rollback actions backed by local
snapshots.

### Skill Hub

Present the Hub as passive local storage. Pairing, visibility, pinning, and
integrity state are product concepts; executing Skills, installing dependencies,
or copying Skills into workspaces are outside the client boundary.

### Mobile Relay

Mobile Relay focuses on pairing and gateway choice. Diagnostic protocol state
stays hidden unless it is needed to unblock pairing.

### Runtime

Runtime shows packaged client-local modules in a left/right module inspector.
It should not become a raw dump of service internals.

### Settings

Settings covers known paths, manual binaries, portable data root, server
profile, client preferences, archive settings, and a single client log export
button. It should not render raw activity logs or become a registry for server
business modules.

## Accessibility

- Text contrast: warm white (#f0eadc) on black crystal (#07070e) achieves
  ~16:1 (exceeds WCAG AAA).
- All command buttons, lists, and dialogs must be keyboard navigable.
- Icon-only controls require tooltips.
- Readiness states such as ready, blocked, and unverified require visible text
  labels and cannot rely on color alone.
- Long paths, command output, and config previews must wrap or scroll without
  obscuring adjacent controls.
