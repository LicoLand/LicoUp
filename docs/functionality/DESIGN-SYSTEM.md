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

`ContinuousStrokePainter` and `ContinuousRoundedBorder` fill one ring between
the outer and inner rounded rects, including all four edges and corner arcs.
Content-layer cards, inputs, chips and themed outlines share that draw. A
content outline must not be assembled from separate line and arc widgets,
painted as a stroked round rect or circle, or painted twice by a Material
border and an overlay rim.

Control-layer glass is a different owner. `LicoGlass` paints unclipped
shadows, then one clip around optional lens displacement, blur, luminosity
and fill, then the child, then a 1 px conic specular rim in the foreground.
The clip does not wrap the rim. Overlay glass uses a sweep-gradient catch of
light (lit arc plus a far-edge whisper). Small glass controls (outlined
buttons, search) keep that light/shadow treatment but enclose the full
silhouette so the ring never drops out. Neither is a uniform-alpha hairline.
Opaque glass controls skip backdrop reads so an empty background is not
refracted into a grey pill. Nested glass on glass is forbidden: ghost header
icons already inside overlay glass do not receive a second glass surface.
Search capsules and outlined circular buttons use this glass owner; they do
not use `ContinuousRoundedBorder` as their material edge. Focus remains a 2 px
interaction ring, not a material rim.
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
explicit glass treatment. Content-layer rims use uniform alpha around the
entire shape. Glass rims do not.

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
and indicates only the work still in flight. Current-page initialization does
not wait for optional background update checks or service warmups. Those tasks
continue independently and retain their own failure reports. Cached usage appears before its
fresh scan completes. Errors belong to their owning result or notification.

Before the first usable usage report, Statistics shows a small progress
indicator with `正在加载中` (`Loading` in English) beneath it. This state
covers the initial cache read and scan. A completed empty result has an empty
state; refreshing an existing report keeps its charts visible.

Statistics selects only usage data and relevant controls. Quota or diagnostic
updates do not rebuild its chart subtree. Usage viewport projections and chart
series are cached by their actual data, grouping and display window. Color
assignments remain stable across refreshes, windows and source ordering.
Labels, values and tooltips identify series independently of hue.

Series fills are translucent vertical gradients, strongest at the band's top
edge and fading toward the baseline, so stacked volume reads as light rather
than pasted slabs. Stacked bands are smoothed with monotone cubic
interpolation, so a boundary never overshoots into the band above it. The Total
usage bar stays pure white in both themes. Every
band owns a crisp luminous top edge in its own hue — a 1px rounded line over
a soft same-hue bloom — and that edge, not a shadow or a gap, keeps
neighbouring bands apart. A day with zero usage contributes no height above
another series, and zero-only intervals draw no area: each positive run closes
at its neighboring zero samples. A single-day timeline keeps its stacked bar
with 2px segment corners, a 1px day gap, the same gradient fill, and the same
top edge. Rendering never changes the reported usage values.

The plot has four horizontal rules, at zero, both thirds and the axis maximum.
The three upper rules are 0.5px hairlines in `line` at 0.28 alpha; the zero
baseline is 1px in `lineStrong` at 0.5 alpha. Value labels are compact, medium
weight and right-aligned in the axis gutter. At most five date labels sit under
the plot, with the two end labels flush against its edges. Hovering a day draws
one 0.5px vertical hairline in `text` at 0.35 alpha and, on every visible band
boundary, a 3.5px dot in that band's hue inside a 1.5px `surface` halo.

Agent charts use saturated, opaque brand hues whose luminance is spread across
the ring, so stacked fills read as separate bands instead of one pastel mass.
Antigravity, Kimi Code and GitHub Copilot use distinct blue-to-purple colors;
Kilo Code uses yellow and Claude Code uses orange. Other Agents receive fixed,
distinct assignments. Light themes deepen these hues for contrast. Plot areas,
bars, legend swatches, hover rows and hover markers share the same color
authority. The legend wraps in usage rank as quiet chips — an 8px dot, the
Agent name in 12px medium `textSecondary`, its total in 12px semibold `text`
with tabular figures — without borders or a chip background. The legend ranks
by total descending; the stack plots ascending totals instead, so the
lowest-usage series hugs the baseline and the largest closes the top.

Model charts use shades within the model developer's color family. Stronger
models use deeper shades; for Claude's orange family the order is Fable, Opus,
Sonnet and Haiku, from deepest to lightest, when those models are present.
The native display name selects the developer family consistently across the
plot, legend and hover rows; canonical IDs keep unknown-model colors stable.
Color never changes the model's availability or capabilities. The palette
follows the categorical and sequential separation in
[Carbon's chart color guidance](https://carbondesignsystem.com/data-visualization/color-palettes/).

One canonical model has one usage row across source applications, reasoning
efforts and speed modes. A source name such as Cursor is not a model name.
An expandable row uses a right-pointing disclosure arrow when closed and a
downward arrow when open. Its expanded view shows a segmented source-share bar
and the corresponding numeric usage below. Hovering a source segment exposes
that source's effort and speed breakdown in the same glass card as the waveform
hover: header and total above, color swatches and names aligned left, amounts
aligned right. The daily card varies only its header and totals: it leads with
the date, lists its series, then closes with a Total row under a hairline
divider in `line`. Card text is 12px, swatches are 7px, amounts use tabular
figures, padding is 12px and corners are 12px. Missing effort has no placeholder
row. A partially known breakdown does not change the header total. Unknown
attribution stays unknown.
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

Desktop messaging places a content-sized identity capsule at the upper left and
one circular ellipsis menu at the upper right. Long titles truncate within the
available width. The direct-conversation menu retains history, new-conversation
and details access; the group menu retains the member-list toggle. Menus support
keyboard activation, Escape dismissal and focus return to the trigger. The
identity capsule has generous horizontal padding. The group member list starts
collapsed and opens from the ellipsis menu.

The desktop messaging composer is a rounded rectangle even for a single line.
Its text area sits above an action row with attachment and group controls on the
left and send/cancel on the right. Typing, wrapping and clearing change the input
height without morphing the container into a pill. Existing draft, attachment,
mention, model, assistant and cancellation ownership stays with its current
feature. Transcript clearance, the latest-message action and the member list
follow the actual composer height. A layout with an external composer clips only
the measured internal composer, preserving the controls above it. Mobile and
console layout geometry retain their respective owners.

The group action row uses a bare plus glyph, and the capsule row above the
composer leads with the Assistant identity capsule followed by the Adaptive
Flywheel capsule — both glass, the same height. The Assistant name opens its
editor in a centered dialog, and a small purple toggle at the trailing edge
pauses or resumes future Assistant participation. An active capsule carries the
purple-and-gold sunset light on its rim and across the name; paused or
unconfigured capsules rest as plain glass. Reduced motion keeps a static rim.
Inactive names remain readable. Before the send action, a quiet readout shows
the active Assistant's selected model in the readable text color with its
reasoning effort muted behind it; it opens the same editor, hides the effort
half when no effort is configured, and disappears entirely while the Assistant
is paused or unconfigured. The Adaptive Flywheel capsule opens its
configuration only. Configuration and
message routing belong to the [Adaptive Flywheel flow](ADAPTIVE-FLYWHEEL.md#group-conversation-start).

桌面消息界面左上角使用随内容收窄的身份胶囊，右上角使用一个圆形三点菜单。
长标题在可用宽度内省略。单聊菜单保留历史、新建与详情入口，群聊菜单保留成员
名单显隐，默认收起；菜单支持键盘操作、Escape 关闭和焦点返回。身份胶囊采用
更宽的左右内边距。桌面消息输入框始终采用
圆角矩形，上方编辑文字，下方左侧放附件与群组控件、右侧放发送或取消。输入、
换行与清空只改变高度，不再切换成胶囊。草稿、附件、提及、模型、助手和取消的
原有功能属主不变。正文留白、回到最新消息按钮和名单随输入区实际高度避让；
外置输入框布局只裁掉实测的内部输入区，保留其上方控件。移动端与控制台的布局
几何仍由各自属主维护。

群聊操作行使用不带圆形底的加号；输入框上方胶囊行先放助手身份胶囊、再放
Adaptive Flywheel 胶囊，两者同为玻璃材质、同高。点击助手名称打开独立的助手编辑框；
尾部一枚紫色小开关控制后续助手参与。激活时助手胶囊边框与名称同披紫金晚霞流光，
暂停或未配置时回到素玻璃；减弱动态时保留静态边框，关闭时文字仍清晰可读。发送按钮
前方有一处安静的模型展示器：以正文色显示激活助手已选的模型名称，思考强度以弱化色
跟在其后，点击同样打开助手编辑框；未配置思考强度时不显示后半段，助手暂停或未配置
时整体消失。Adaptive Flywheel 胶囊仅打开其配置；配置和发送语义
由[对应流程](ADAPTIVE-FLYWHEEL.md#group-conversation-start)维护。

The product-owned **Local** group is the highest-priority cold-start data
target. After native state admission, load the canonical group catalog and
Local's latest 20 events before target-cache hydration, Agent discovery,
model catalogs, optional service warmups, or other background reads. Its
native snapshot populates the existing conversation cache; opening Local
reuses that snapshot without another first-page read. Restore a saved group
view before awaiting Agent discovery. Loading priority does not overwrite an
explicit saved or current conversation selection, and a group read failure
stays visible in its owner without preventing independent startup work.

Never join canonical group readiness and Agent discovery behind a shared
completion barrier. The native canonical store owns Local's identity,
membership and history; the client must not invent a placeholder group or
substitute Agent history for canonical events. Keep this ordering documented
at the bootstrap and conversation-entry call sites.
The first-frame Gateway callback also waits for client initialization; window
visibility alone must not let service startup overtake Local's queued reads.

Cold native history waits only for its Agent executable binding; model catalog
discovery continues in the background. Admitted target scans run in bounded
RPC workers so discovery leaves the host's request loop responsive.
Canonical active and archived lists use
one native catalog snapshot, preserving archived child relationships. Neither
path changes the other's conversation authority.

A group's native-history loading state covers its associated native sessions.
Publish each completed session immediately; concurrent refresh requests join
the current read instead of invalidating it and starting another worker batch.
Only a group or membership change invalidates an unfinished read. A completed
batch releases its loading state and allows the next refresh.

Recognized native-history stores own empty results as well as populated ones.
For Cursor, an absent or empty conversation in its IDE or CLI schema must
never trigger generic database scanning. Exact reads retain their native
identity and delegated lineage, and unrelated database records are not a
second source to search when the requested conversation is absent.

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
its reply bubble before response text arrives. While waiting, the bubble holds a
small living energy orb: three luminous currents orbit inside a soft sphere at
distinct integral rates with a breathing core, so the ambient loop never repeats
a visible pattern. The first reply
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

The default loading effect is a small spinning progress arc. Settings offers
Simple spinner, Static indicator, and Spinner with conversation particles. The
selection persists with appearance preferences and changes at runtime without
replacing conversation content or draft state. Empty conversations stay idle
under the default and static options.

Loading widgets use `LicoLoadingIndicator` and the selected
`LicoLoadingEffectScope`. A renderer supplies an indicator builder and may supply
a conversation-scene builder. The application catalog registers compiled
factories; only the selected, mounted effect creates its visual resources.
The scene contract carries layout bounds and presentation completion, independently
of the particle simulation. Without a scene builder, the host skips measurement,
brand-mark sampling, and decorative frame scheduling. Data readiness, errors,
sending, and cancellation remain with their existing owners.

The optional particle effect shows a silver-white sphere centered in an empty
conversation's content area. Particles form a dense, irregularly sampled thin
spherical shell. Continuous tangential curl motion creates folding density and
overlapping front and rear layers; it is not a latitude grid rotating as one
object or a pair of sinusoidal bands. Fine flow and depth shading give the sphere
volume without explanatory text. The visual reference is the particle
study on [Van Lent](https://vanlent.dev/); LicoUp owns its Flutter rendering and
interaction implementation. Only the particle motion is referenced. The renderer
leaves its canvas transparent and adds no background grid, reference-site
decoration, or texture behind the sphere.

Conversation and Statistics loading share a small progress indicator. Loading
does not start the empty-conversation particle scene; the optional scene appears after
the first read settles without content. Reduced motion keeps a static progress
arc. Each screen owns its loading state independently of the renderer.

With the particle effect enabled, the first send moves the same particle
identities left into layered waves. They then settle into the actual Agent
avatar and composer outline. Transition
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
