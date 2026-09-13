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
| `composer-activity-effect` | `breathing`, `pulse` | Working composer outline; breathing is the default |

Color tokens continue to define the semantic palette. These tokens cannot
supply widths, spacing, component order, destinations, callbacks or commands.
Geometry remains in layout/profile and shared component metrics. A custom
style therefore changes the presentation of the current layout, never its
functional structure.

Dashboard assigns transparency by component role: its sidebar is 90%
transparent (10% fill opacity), while conversation bubbles are fully opaque.
Sidebar transparency affects its background, not the legibility of its text,
icons or focus state. These Dashboard roles do not change another layout's
surface treatment. A shared opacity multiplier must not make message bubbles
translucent.

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
a semantic name and keyboard activation; an unlabeled icon also has a tooltip.
Primary navigation already has visible text, so it does not repeat that text
in a hover bubble. Status never relies on color alone. Text and buttons align
on the same content edges.

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
The sidebar, conversation header and composer must also avoid a second outline
from an enclosing surface. Visual review includes the straight-to-curve joins,
all four sidebar corners and the navigation divider. The composer's attachment
button uses the same glass control treatment as its neighboring controls.

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
The three detail destinations form one compact glass selector in the title bar,
immediately left of refresh. Its 16 px labels sit inside a 2 px inset, with a
12 px outer radius and 10 px selection radius. Localized text and text scaling
determine its width. On narrow panes, the title stays on the first line and
the selector and refresh move together to a second line. Keyboard selection,
theme changes and reduced motion follow the shared control policy.

The single title-bar refresh acts on the selected Overview, Plugins or Skills
view and reflects only that view's loading state. Embedded Plugin and Skill
views have no second refresh button; standalone views keep their own title bar.
Selection and content transitions preserve each page's scroll and filter state.

Settings builds and subscribes to the section being used. Locale, theme,
layout, storage, archive, updater and logs select their own projection fields.
The updater aligns its current/available versions, status and actions with
consistent button dimensions. Resource collection continues in its existing
owner while resource cards and the obsolete tool-catalog setting remain hidden.
An update check distinguishes an available update, no newer published version,
missing update metadata and an actual failed operation. Confirmed current
versions use green status text with a readable label. A failed network request
or failed integrity verification must not appear as an up-to-date result.

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

Before the first usable usage report, Statistics shows the shared rotating
particle globe with `正在加载中` (`Loading` in English) beneath it. This state
covers the initial cache read and scan. A completed empty result has an empty
state; refreshing an existing report keeps its charts visible.

Statistics selects only usage data and relevant controls. Quota or diagnostic
updates do not rebuild its chart subtree. Usage viewport projections and chart
series are cached by their actual data, grouping and display window. Color
assignments remain stable across refreshes, windows and source ordering.
Labels, values and tooltips identify series independently of hue.

Data fills, series swatches and usage bars are fully opaque. The Total usage
bar is pure white in both themes. Stacked areas have no colored outline:
each positive run closes at adjacent zero samples, and zero-only intervals
draw no series area. A day with zero usage contributes no height or colored
line above another series; rendering never changes the reported usage values.

Agent charts use a rainbow palette. Antigravity, Kimi Code and GitHub Copilot
use distinct blue-to-purple colors; Kilo Code uses yellow and Claude Code uses
orange. Other Agents receive fixed, distinct assignments. Existing brand colors
take precedence over arbitrary chart order.

Model charts use shades within the model developer's color family. Stronger
models use deeper shades; for Claude's orange family the order is Fable, Opus,
Sonnet and Haiku, from deepest to lightest, when those models are present.
Color never changes the model's availability or capabilities.

One canonical model has one usage row across source applications, reasoning
efforts and speed modes. A source name such as Cursor is not a model name.
An expandable row uses a right-pointing disclosure arrow when closed and a
downward arrow when open. Its expanded view shows a segmented source-share bar
and the corresponding numeric usage below. Hovering a source segment exposes
that source's effort and speed breakdown in the same glass card as the waveform
hover: header and total above, color swatches and names aligned left, amounts
aligned right. Missing effort has no placeholder row. A partially known
breakdown does not change the header total. Unknown attribution stays unknown.
The Rust [model registry](../architecture/MODEL-REGISTRY.md) owns identity;
native usage owns aggregation, and the renderer owns color and disclosure state.

## Assistant model selection

The model picker displays names without scores, task tags or capability prose.
Official models precede custom-provider models. Within each provider group,
numeric model versions sort from newest to oldest; textual sorting must not
place version 5.9 ahead of 5.10. Product names retain their spacing, including
`GPT-6 Astra`.

Assistant and workflow model pickers prepare their catalog, provider groups,
search results and row positions when those inputs change. Scrolling and hover
reuse that projection and construct only visible rows. A large loaded catalog
must not cause a new fetch, full-directory label scan or complete list layout
on each interaction. Row keys and the selected-model position stay stable.

Provider groups remain visible for multi-provider Agents, including Antigravity
and Kimi Code. Claude Code exposes its admitted model catalog, rather than only
the configured default. Discovery and native capability contracts determine
which models and efforts are available; presentation does not invent them.
Reasoning labels use English and ascending intensity: Low, Medium, High,
Extra High and Max. `Extra High` is the display label for the native `xhigh`
value; changing the label does not change the dispatched value.

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

Message text remains selectable and copyable. An accepted Agent dispatch creates
its reply bubble before response text arrives. Three metal-like points exchange
velocity through equal-mass elastic collisions while waiting. The first reply
text replaces that waiting treatment immediately; reasoning and tool events do
not count as reply text. A terminal failure, cancellation, or completion also
ends the waiting treatment and retains its real outcome.

Thinking and tool activity are not inline process cards in the transcript.
Each Agent bubble has an ellipsis action outside its upper-right corner. Its
**Execution process / 执行过程** menu item uses an eye icon and opens the
execution viewer for that reply. Sender identity and all message actions
retain semantics and keyboard access across layout profiles.

The execution viewer is a floating surface. Its header places the Agent icon,
name and conversation title on the left, search in the center, and close on
the right. Available execution records and metadata appear oldest to newest,
with full selectable content, clear event boundaries, and code treatment for
structured or literal output. The local viewer does not redact, summarize,
trim, or silently truncate the contents it receives. Information never emitted
by an upstream Agent is not invented. Public fixtures and visual evidence
remain synthetic.

The viewer initially positions at the newest record and updates while work
continues. Following the latest record stops when the reader scrolls away or
jumps to a search match; new records remain available through a return-to-latest
action. Enter moves through keyword matches and highlights the selected match,
including records outside the current rendered viewport. Closing restores
focus to the invoking action.

Large raw outputs use bounded text chunks and cooperative layout. Preparing a
long history must leave search and close responsive; live additions retain the
already displayed content while the new paragraphs are prepared.

Conversation lists keep their scroll simulation active after a gesture ends.
Release velocity produces inertia, and overscroll springs back into range.
Pulling beyond the refresh threshold dispatches one refresh and shows its
activity without holding the list at a negative offset. The authoritative
loading state controls completion; a decorative ticker pause must not stop
the Scrollable's own simulation.

## Motion and accessibility

An empty conversation shows a silver-white particle sphere centered in the
conversation content area. Particles form a dense, irregularly sampled thin
spherical shell. Continuous tangential curl motion creates folding density and
overlapping front and rear layers; it is not a latitude grid rotating as one
object or a pair of sinusoidal bands. Fine flow and depth shading give the sphere
volume without explanatory text. The visual reference is the particle
study on [Van Lent](https://vanlent.dev/); LicoUp owns its Flutter rendering and
interaction implementation. Only the particle motion is referenced. The renderer
leaves its canvas transparent and adds no background grid, reference-site
decoration, or texture behind the sphere.

Statistics loading and the empty conversation share one pure visual particle
engine. Each screen owns its loading state independently of that renderer.

On the first send, the same particle identities flow left into layered waves,
then settle into the actual Agent avatar and composer outline. Transition
positions and velocities remain continuous. Targets come from measured layout
geometry, including a relocated desktop composer; no fixed screen coordinates
or replacement screenshots define the transition. The composer remains usable
throughout. Sending, dispatch, and streamed text never wait for an animation.
Changing conversations disposes that conversation's visual transition.

Particle and waiting effects use isolated paint updates rather than rebuilding
conversation content each frame. Particle buffers remain stable during motion;
completed assembly stops its ticker. Offstage and reduced-motion tickers stop.
Reduced motion keeps a static sphere and a legible waiting state without the
travel or collision effect. Existing nonempty conversations do not replay the
empty-state assembly.

Conversation work is shown on the composer's existing outline, with breathing
as the default treatment and a pulse as an alternate theme effect. The effect
can change while the app is running without changing the active conversation
or turn. A separate progress strip above the conversation is not used. The
outline keeps one geometric stroke in every animation phase; reduced motion
shows a static working state.

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
