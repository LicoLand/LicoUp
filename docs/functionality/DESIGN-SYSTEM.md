# LicoUp Client Design System

| Relationship | Authority |
| --- | --- |
| Product scope | [Client functionality](CLIENT-DESKTOP.md) |
| State and presentation ownership | [Architecture](../architecture/README.md) |
| Font files, licenses and upstream revisions | [Bundled fonts](../../apps/desktop/assets/fonts/README.md) |
| Implementation tokens | `frontend/shared/ui/`, `frontend/appearance/` and the bundled theme catalog |

This document owns the desktop client's visual and interaction system. Theme
styles describe appearance. Layout profiles describe geometry. Named feature
Bindings provide functional state and commands. These three owners remain
independent when a user changes settings.

## Orbital appearance

Orbital uses deep black, silver gray and electric yellow. Large reading surfaces
stay neutral. Silver identifies interactive text, focus and precise outlines.
Electric yellow marks the primary action and selected brand controls. Success,
warning and failure retain distinct semantic colors and visible labels or icons.

| Role | Dark theme | Purpose |
| --- | --- | --- |
| Window | `#0E0F11` | Deep black background |
| Content | `#1B1C1F` | Primary surface |
| Inset controls | `#292A2E` | Quiet grouping and selection |
| Floating surfaces | `#393A3F` | Menus and popovers |
| Primary text | `#F4F5F7` | Reading and titles |
| Secondary text | `#CED0D5` | Supporting facts |
| Metadata | `#ACADB3` | Time, counts and secondary state |
| Brand | `#E7F22E` | Primary action fill |
| Interaction | `#CBD0D9` | Links, focus and controls |

The light style uses the same yellow identity with white content and silver
surfaces. Both styles are selectable. The system option resolves the selected
brightness from the operating system. Theme selection persists without changing
layout, navigation, running work, subscriptions, input or scroll ownership.

Settings labels this control **Theme style / 主题风格**. The existing preset
identifiers remain storage identifiers; they are not product-facing names.
Theme files load and reload at runtime through the existing catalog.

The optional visual tokens are intentionally bounded:

| Token | Values | Effect |
| --- | --- | --- |
| `font-family` | `geist`, `system` | Interface typeface |
| `icon-style` | `outlined`, `rounded` | Supported common control glyphs |
| `motion-scale` | `0.75`, `1`, `1.25` | Shared motion durations |
| `surface-opacity` | `0.85`, `0.9`, `0.95`, `1` | Surface fill opacity |
| `component-finish` | `crisp`, `glass` | Static surface sheen |

Color tokens continue to define the semantic palette. These tokens cannot
supply widths, spacing, component order, destinations, callbacks or commands.
Geometry remains in layout/profile and shared component metrics. A custom
style therefore changes the presentation of the current layout, never its
functional structure.

## Typography and content

Geist Sans is the interface family. Geist Mono marks commands, paths, identifiers
and exact values. Noto Sans SC supplies Chinese glyphs before any platform
fallback. All three families ship locally under the SIL Open Font License 1.1;
font loading causes no network requests.

`LicoTypography` owns the scale and fallback order. Titles use 18–24 px with
semibold weight; the Agent detail identity uses 28 px. Conversation reading text
uses 14 px with a 1.5 line height.
Body and control text use 13 px; supporting text uses 12 px. Numeric readouts
use tabular figures. Text scaling remains available.

A title names the current task or destination. Labels name controls. Secondary
copy is reserved for a factual distinction that affects a decision. Repeated
subtitles and descriptions of obvious controls are omitted. Errors, warnings,
permission context and non-obvious behavior remain visible. Icon actions have
a tooltip, semantic name and keyboard activation; status never relies on color
alone. Text and buttons align on the same content edges.

Body, supporting and metadata colors clear 4.5:1 against their intended
surfaces. Meaningful non-text graphics clear 3:1. Electric yellow is a fill and
mark role; light-mode text uses its dark ink or a readable interaction role.

## Component ownership and geometry

`BaseSurface` and `BaseControlSurface` are abstract. Feature components specialize
them with named constructors that constrain tone and geometry. Generic base
instances cannot appear in a feature. Agent, Plugin, Skill, archive and
continuous-assistant surfaces each own their specialization. Changes to a
feature's local treatment cannot silently alter other feature types.

`ContinuousStrokePainter` draws one inset rounded rectangle path, including
all four edges and corner arcs. Search capsules, glass controls and structural
rims share it. A capsule outline must not be assembled from separate line and
arc widgets or painted twice by a Material border and an overlay rim.

| Shared metric | Value |
| --- | ---: |
| Standard outline | 1 px |
| Focus outline | 2 px |
| Content card radius | 12 px |
| Floating surface radius | 10 px |
| Control/chip radius | 8 px |
| Recessed well radius | 6 px |
| Content spacing | 4 / 8 / 16 / 24 px |

Nested rounded controls use `inner radius = outer radius − gap`, bounded at
zero. Layout profile metrics own window, sidebar and conversation capsule
geometry. Theme files cannot override these dimensions. Opaque glass controls
do not perform backdrop blur; translucent conversation overlays retain their
explicit glass treatment. Rims use uniform alpha around the entire shape.

## Navigation and feature pages

The feature navigation exposes Agent Center, Statistics, Model Gateway and
Mobile Pairing. Conversation and Settings remain primary shell destinations.
Plugin Management and Skill Center remain functional views inside Agent detail.
Their independent navigation entries are hidden, including saved feature-order
entries and search navigation. Chat Channels lives in Mobile Pairing and keeps
its existing Telegram configuration and refresh behavior.

Agent cards open a detail page with a clear identity, official description and
the existing install/update controls. The detail page provides Overview,
Plugins and Skills. Descriptions come from official Agent sources maintained
in the catalog; subjective ratings, rankings and adaptation-depth opinions do
not appear. Plugin and Skill views use the selected Agent context.

Settings builds and subscribes to the section being used. Locale, theme,
layout, storage, archive, updater and logs select their own projection fields.
The updater aligns its current/available versions, status and actions with
consistent button dimensions. Resource collection continues in its existing
owner while resource cards and the obsolete tool-catalog setting remain hidden.

Layout previews are produced by each registered layout profile. They depict
that profile's actual navigation, sidebar and detail/composer placement and
preserve the full 16:10 composition. A preview is not a separate speculative
layout or an alternate style-dependent arrangement.

## Independent loading and efficiency

Each ready section appears immediately. Agent catalog entries, Plugin and Skill
results publish incrementally; an unfinished sibling does not replace ready
content with a full-page loading barrier. Refresh keeps existing content visible
and indicates only the work still in flight. Cached usage appears before its
fresh scan completes. Errors belong to their owning result or notification.

Statistics selects only usage data and relevant controls. Quota or diagnostic
updates do not rebuild its chart subtree. Usage viewport projections and chart
series are cached by their actual data, grouping and display window. Charts
use a single silver-to-yellow series ramp with stable label assignments.
Labels, values and tooltips identify series independently of hue.

This approach follows Flutter's guidance to localize rebuilds, retain unchanged
children and build long lists lazily. Paint-only activity uses repaint
boundaries and avoids per-frame descendant rebuilds or backdrop reads.
[Flutter performance guidance](https://docs.flutter.dev/perf/best-practices).

## Conversation loading and hierarchy

A conversation initially displays the latest 20 messages. Scrolling toward
older history requests 20 more. The existing page cursor and reading-position
controller preserve the visible anchor; streaming and new messages continue
to update the newest end without discarding earlier loaded content.
Mounted messages register their actual geometry under stable message IDs.
Layout-time correction preserves that visible message while variable-height
rows change, without using estimated total list extents or jumping after paint.
This follows Flutter's [viewport correction contract](https://api.flutter.dev/flutter/widgets/ScrollPosition/applyContentDimensions.html)
and [sliver child layout offsets](https://api.flutter.dev/flutter/rendering/SliverLogicalParentData/layoutOffset.html).

Canonical/group transcripts use the same 20-entry page size. Native event
sequences own their backward cursor, including when deleted events leave gaps.
Recovered task-card anchors outside the current page remain supplemental;
they never advance the contiguous history cursor past unseen events.

Native delegated conversations are identified by recorded lineage. They appear
as expandable cards under their parent conversation, never inferred from
prompt text, names or paths. Expanding a child loads its latest 20 messages;
older child history loads in batches of 20 through the same exact-session page
contract. Child expansion and paging preserve the selected parent conversation.
An expanded child refreshes when its native source revision changes, even if
the message count is unchanged. Display timestamps do not act as cache revisions.
Nested work and tool-only children remain accessible. Collapsing a card never
cancels work. A bounded first page is not a content truncation policy.

Message text remains selectable and copyable. Process metadata stays distinct
from authored content. Sender identity, activity, copy and disclosure controls
retain semantics and keyboard access across layout profiles.

## Motion and accessibility

Silver-white parsing grains and flowing highlights indicate active work. They
are deterministic, bounded paint operations over an existing small surface.
There is no idle particle field or continuous animation after the activity
ends. Offstage tickers and reduced-motion tickers stop; the activity remains
legible as a static state.

Reduced motion follows the system by default. On macOS, the native environment
observes `NSWorkspace.accessibilityDisplayShouldReduceMotion` initially and on
accessibility display-option changes. Settings shows that system-managed state.
Other systems combine Flutter's accessibility signal with the persisted
**Reduce motion / 减少动态效果** setting. A manual preference cannot turn off a
system request for reduced motion. Theme transitions, shared motion and activity
indicators consume the effective environment preference.

## Verification

Focused tests cover theme contrast, complete Material color roles, visual-token
validation, unchanged geometry across theme changes, component specializations,
continuous strokes, keyboard actions, activity ticker lifetime, asynchronous
partial publication, usage caching, message paging and native lineage cards.
Synthetic layout and feature renders provide visual evidence without real
user content. The complete regression and installed-client verification follow
[Contributing](../../CONTRIBUTING.md#local-client-verification).
