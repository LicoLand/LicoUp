# LicoLite Client Design System

This document describes the visual and interaction direction for the LicoLite
Flutter desktop client. Product scope is controlled by
[`docs/functionality/CLIENT-DESKTOP.md`](../docs/functionality/CLIENT-DESKTOP.md).

## Product Identity

LicoLite Client is a lightweight local environment manager for a developer's
machine. It makes target-native MCP configuration, local Skill Hub state, thin
model forwarding, and configuration recovery understandable without becoming a
new agent framework.

The UI must feel:

1. **Local**: actions should map to visible local targets, config files,
   snapshots, and CLI-backed operations.
2. **Precise**: every write path should show what target, path, field, token
   reference, or snapshot is affected.
3. **Quiet**: the app is an operational tool, not a marketing surface or a
   server console clone.

The client must not present removed Console, Mail, DataConnector, upload queue,
Knowledge Graph, or server API panels as first-class product surfaces.

## Visual Language — Crystal Obsidian

The client shares the LicoLite crystal obsidian aesthetic with the server console
and licolite.com website. Dark-first, with warm gold as the brand accent, ice-blue
for informational/technical elements, and linen warm-white for text.

### Core Palette

| Role | Value | Name |
| --- | --- | --- |
| App background | `#0a0a14` | Obsidian |
| Surface | `#10101c` | Obsidian Surface |
| Subtle surface | `#161624` | Obsidian Subtle |
| Inset | `#06060e` | Obsidian Deep |
| Text primary | `#ede6d6` | Linen |
| Text secondary | `#b0a899` | Linen Dim |
| Text muted | `#7a8ea8` | Silver |
| Border | `#2a2a40` | Obsidian Border |
| Brand accent | `#c9a96e` | Licorice Gold |
| Brand strong | `#f0d28c` | Gold Light |
| Info/technical | `#4fc3f7` | Ice Blue |
| Success | `#80deaa` | Crystal Green |
| Warning | `#f0d28c` | Gold Light (shared with brand strong) |
| Danger | `#f07878` | Crystal Red |

### Light Mode (when user prefers light)

For users who prefer light mode, the client falls back to the `geek-light-blue`
preset. The crystal obsidian palette is the brand-default dark experience.

### Theme Implementation

The Flutter client builds `ThemeData` from appearance preset tokens via
`LicoThemeColors` (see `lib/src/ui/theme.dart`). The `licolite-crystal` preset
is the default dark theme.

Key mapping:
- `background` ← `bg-base` (#0a0a14)
- `surface` ← `bg-surface` (#10101c)
- `surfaceLow` ← `bg-subtle` (#161624)
- `text` ← `text-primary` (#ede6d6)
- `textMuted` ← `text-muted` (#7a8ea8)
- `primary` ← `brand` (#c9a96e)
- `primaryStrong` ← `brand-strong` (#f0d28c)
- `textOnPrimary` ← `text-on-brand` (#0a0a14)

## Navigation

The app uses a desktop split view with a stable first-level sidebar. The only
default sections are:

- Agents
- MCP Plugins
- Skill Hub
- Model Forwarding
- Activity And Snapshots
- Settings

Each section should expose concrete target state and actions. Avoid generic
dashboard pages that summarize the product instead of helping the user inspect
or change local configuration.

Sidebar uses obsidian-deep background. Active items show gold-tinted highlight.
Inactive items use silver (#7a8ea8) text.

## Typography

Use system fonts for a native desktop feel. Use monospace text only for paths,
commands, JSON snippets, token environment variable names, and target-native
configuration fields.

- Body text: system sans-serif, 14px, linen color
- Headings: system sans-serif, light to normal weight
- Code/paths: monospace, ice-blue (#4fc3f7) for emphasis or silver for subdued

## Surface & Depth

Depth in the client follows the same crystal obsidian model as the web console:

1. **Window/scaffold**: `#0a0a14` (obsidian base)
2. **Panels/cards**: `#10101c` (surface)
3. **Hover/selected**: `#161624` (subtle)
4. **Inset/code**: `#06060e` (deepest)

Card borders use 1px at rgba(201, 169, 110, 0.06) — ultra-subtle gold tint.
Hover brightens to 0.12-0.15.

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

The supported target list is Antigravity, Claude Code, Codex, Cursor,
GitHub Copilot, Hermes Agent, Kilo Code, OpenClaw, and OpenCode.

### MCP Plugins

Treat LicoLite MCP as a peer plugin. Show target-native MCP fields, version/status
when available, update/repair triggers, and rollback actions backed by local
snapshots.

### Skill Hub

Present the Hub as passive local storage. Pairing, visibility, pinning, and
integrity state are product concepts; executing Skills, installing dependencies,
or copying Skills into workspaces are outside the client boundary.

### Model Forwarding

Forwarding controls should make the selected profile and target explicit. The
UI should not suggest that LicoLite Client owns a planner, hidden tool loop, or
long-running autonomous session.

### Activity And Snapshots

Activity should read like an audit trail for local client actions. Snapshot
views must show enough target/path/hash context for rollback decisions without
turning into a full filesystem backup interface.

### Settings

Settings covers known paths, manual binaries, portable data root, server
profile, and client preferences. It should not become a registry for server
business modules or removed local runtime services.

## Accessibility

- Text contrast: linen on obsidian achieves ~14:1 (exceeds WCAG AAA).
- All command buttons, lists, and dialogs must be keyboard navigable.
- Icon-only controls require tooltips.
- Long paths, command output, and config previews must wrap or scroll without
  obscuring adjacent controls.
