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
Content-layer cards, inputs, chips and themed outlines share that draw. Input
focus transitions retain this border owner; floating labels remove only the
intersecting ring, following the same left-to-right and right-to-left gap
geometry as Material inputs. A
content outline must not be assembled from separate line and arc widgets,
painted as a stroked round rect or circle, or painted twice by a Material
border and an overlay rim.

Control-layer glass is a different owner. `LicoGlass` paints unclipped
shadows, then one clip around optional lens displacement, blur, luminosity
and fill, then the child, then a 0.75 px specular rim in the foreground.
The clip does not wrap the rim. Both overlay glass and small controls use one
low-contrast, broad linear light field projected across the actual surface
width and height, from above-left at rest. Brightness changes gradually along
straight edges and corner arcs, with a weak edge on the far side. Pointer
motion changes the light direction without a concentrated angular highlight,
bright point, closed bright outline or second bevel. The [Apple-Style material reference](https://github.com/Tsdsj/Apple-Style/tree/d0feb3f1819bd992ef78ee4ac667095f21b26a5c/skills/Apple-Style-Liquid-Glass)
informs this restrained edge treatment.
Opaque glass controls skip backdrop reads so an empty background is not
refracted into a grey pill. Nested glass on glass is forbidden: ghost header
icons already inside overlay glass do not receive a second glass surface.
Search capsules and outlined circular buttons use this glass owner; they do
not use `ContinuousRoundedBorder` as their material edge. Focus remains a 2 px
interaction ring, not a material rim. Focus, warning and high-contrast outlines
paint above the fill so opaque controls cannot hide interaction feedback.
Interaction and accessibility changes update this chrome without replacing the
content subtree, preserving editing focus, selection and local widget state.
Base surfaces paint their structural ring in the foreground without adding
implicit content padding; feature-owned insets remain unchanged.
Each lensed slab owns and reuses its shader, releasing it on replacement or
unmount; only the immutable fragment program is shared. The lens samples inward
along the rounded silhouette normal, calculated directly without repeated
distance-field probes. Displacement increases toward the rim within a band
limited to one quarter of the shorter side and at most 12 px, leaving the face
undistorted even on short controls. Unsupported renderers retain the
blur and specular rim without shader displacement.
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

Data fills, series swatches and usage bars are fully opaque. The Total usage
bar is pure white in both themes. Stacked areas have no colored outline:
each positive run closes at adjacent zero samples, and zero-only intervals
draw no series area. A day with zero usage contributes no height or colored
line above another series; rendering never changes the reported usage values.

Agent charts use muted brand hues with balanced brightness for large opaque
fills. Antigravity, Kimi Code and GitHub Copilot use distinct blue-to-purple
colors; Kilo Code uses yellow and Claude Code uses orange. Other Agents receive
fixed, distinct assignments. Light themes deepen these hues for contrast.
Plot areas, bars, legend swatches and hover rows share the same color authority.
Legend labels and values use quiet medium weights so the chart retains focus.

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

The group action row uses a bare plus glyph, a separated Assistant name, and a
pencil control with a fine 13px glyph. The name toggles future Assistant participation; the pencil
opens the existing Assistant editor in its own centered dialog. An active name
has a purple-and-gold sunset highlight moving from left to right — a molten
gold core leading, a violet aura trailing. Reduced motion renders
a static active treatment. Inactive names remain readable. The capsule above
the composer opens Adaptive Flywheel configuration only. Configuration and
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

群聊操作行使用不带圆形底的加号，与 Assistant 名称之间保留间距，名称后放独立
13px 细铅笔按钮。点击名称切换后续助手参与，点击铅笔在界面中央打开独立助手编辑框。
激活名称以从左向右的紫金晚霞流光表示状态——熔金亮芯在前、紫色霞光相随；减弱动态时使用静态激活样式，关闭时
文字仍清晰可读。输入框上方胶囊仅打开 Adaptive Flywheel 配置；配置和发送语义
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

## Visual reference and style review

The [glass reference board](../assets/design/glass.html) is the accepted material
and conversation composition reference. Its [dark](../assets/design/glass-dark.png)
and [light](../assets/design/glass-light.png) images are actual macOS Impeller
renders of shared Flutter components with synthetic content. The board is a
component composition, not a screenshot of a live conversation or a promise
that every layout has the illustrated background. The viewer also offers the
current production group header and composer in the same scene for comparison.

Before changing component styles, produce a matching review board from real
components in both themes. Show the current and proposed treatment at the same
scale, including corners, long edges, focus and surrounding content. Review the
images before applying the treatment throughout the conversation. Keep the
accepted images in the project; replace them only when the new visual direction
is accepted. A reference board complements behavior tests and actual conversation
review; it does not replace them.

The [capture fixture](../../apps/desktop/integration_test/glass_visual_reference_test.dart)
reproduces this composition without loading user state or contacting an Agent.
Capture proposed images into an ignored output directory; the command runs a
separate synthetic app on the available macOS renderer:

```sh
mkdir -p build/visual-reference
cat > build/visual-reference/capture.xcconfig <<'CONFIG'
PRODUCT_BUNDLE_IDENTIFIER = land.lico.licoup.visual-reference
CONFIG
XCODE_XCCONFIG_FILE="$PWD/build/visual-reference/capture.xcconfig" \
  npm run client:test -- integration_test/glass_visual_reference_test.dart \
  -d macos --enable-impeller \
  --dart-define=GLASS_REVIEW_OUTPUT="$PWD/build/visual-reference"
```

The same run also captures the current production group header and message
composer in the synthetic scene as `conversation-dark.png` and
`conversation-light.png`, beside the reference composition in `dark.png` and
`light.png`. Compare these to the accepted project images before replacing them.

### 视觉参考与样式审阅

[玻璃展示板](../assets/design/glass.html)是已认可的材质与对话构图参考。
[深色](../assets/design/glass-dark.png)和[浅色](../assets/design/glass-light.png)
图片来自共享 Flutter 组件的 macOS Impeller 真实渲染，内容均为合成数据。
展示板展示组件组合，不是实时对话截图，也不要求所有布局使用图中的背景。
查看器也提供相同场景中的当前生产群组顶部栏和输入框，便于对照。

以后修改组件样式时，先用真实组件制作深浅两套展示图，以相同比例比较现状与
候选版本，包含圆角、长边、焦点及周围内容。先审阅图片，再将样式应用到整个
对话界面。已认可的图片长期保留在项目内；只有新的视觉方向获认可后才替换。
展示图补充行为测试和实际对话验收，不能代替它们。上面的捕获入口使用独立的
合成应用，不加载用户状态、不联系 Agent；候选图片写入忽略目录。
同一次运行还在相同场景中捕获当前生产群组顶部栏与消息输入框，输出
`conversation-dark.png` 与 `conversation-light.png`；参考构图输出为 `dark.png`
与 `light.png`。替换项目前先与已认可图片对照。

## Verification

Focused tests cover theme contrast, complete Material color roles, visual-token
validation, unchanged geometry across theme changes, component specializations,
continuous strokes, keyboard actions, activity ticker lifetime, asynchronous
partial publication, usage caching, message paging and native lineage cards.
Synthetic layout and feature renders provide visual evidence without real
user content. The complete regression and installed-client verification follow
[Contributing](../../CONTRIBUTING.md#local-client-verification).
