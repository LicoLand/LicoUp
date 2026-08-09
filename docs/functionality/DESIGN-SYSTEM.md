# LicoUp Client Design System

This document describes the implemented visual and interaction system for the
LicoUp Flutter client. Product scope is controlled by
[`CLIENT-DESKTOP.md`](CLIENT-DESKTOP.md).

**Code is authoritative over this document, and tests are authoritative over
code.** Every numeric rule below is asserted in
`apps/desktop/test/theme_test.dart` or
`apps/desktop/test/design_system_boundary_test.dart`. If a value here fails a
test, change the value — do not relax the test.

## Product Identity

LicoUp is an open aggregation entry point for agents. It exists so a person can
reach every agent on their machine, and every agent a peer chooses to expose,
through one conversation surface they control.

The UI must feel:

1. **Alive** — the product name reads as energetic, and the interface should
   agree. Motion, contrast, and the brand mark carry that.
2. **Precise** — every write path shows the target, path, field, or snapshot it
   affects.
3. **Durable** — this is a surface people keep open all day. Saturated color is
   scarce, neutrals carry the load, and nothing vibrates.

Requirements 1 and 3 pull against each other. The resolution is *distribution*,
not compromise: the palette is energetic where the eye lands briefly and quiet
where the eye rests.

## Visual Language — LicoUp

Lemon yellow for identity and commitment, soda blue for interaction, cool
graphite for everything else. Built-in appearance presets are shown in
settings as **LicoUp Dark** (`lico-soda`) and **LicoUp Light**
(`lico-soda-light`).

### Why the previous three attempts failed

**Attempt 1 — `lico-crystal`.** Hueless black (`#070707`, `#0d0d0d`, `#151515`)
with `#fef100` as the brand. Adjacent surface steps differed by only 2–4 L\*,
effectively invisible, so components could not express depth. `#fef100` is the
highest-chroma colour reachable in sRGB and it was the *primary action* colour.
`brand` was yellow and `warning` was also yellow-orange, so the two were not
reliably distinguishable. And the light preset's brand was cobalt `#2563eb`
while the dark preset's was yellow, so **following the system appearance
silently rebranded the application.**

**Attempt 3 — the enforcement gap.** Attempt 2's palette was corrected to be
clean and vivid, and the app was still shipped illegible, because *the rules
were only tested against the role definitions and never against the point of
use*:

| Defect | Measured |
| --- | --- |
| 30 components passed `colors.primary` straight into an `Icon` or `TextStyle` | lemon glyphs at **1.40:1** on a white surface |
| Light window `#f4f4f6` behind white cards | contrast **1.098** — no card edge, "white mush" |
| `ColorScheme` built with `copyWith` on a Material baseline | **12 roles** left at Material's palette; `secondaryContainer` resolved to teal `#03dac6` and `primaryContainer`/`surfaceTint` to purple `#bb86fc`, drawing a refresh control as a mint circle with a pink glyph |
| Selected cards used a lemon rim at 1.40:1 over a pale lemon fill | acidic, and the rim was invisible |
| Settings rows gapped by 14 px and 10 px | off the 4/8/16/24 scale, uneven rhythm |

The lesson: **a palette can be mathematically perfect and the interface still
unreadable.** Token-level contrast tests prove the roles are sound; they prove
nothing about whether components use the right role. Both must be enforced, and
an incomplete `ColorScheme` is a colour leak.

**Attempt 2 — the dusty correction.** Over-correcting attempt 1 produced
something worse for this product: an interface that read as grey haze. Three
decisions compounded, all pulling the same way:

| Decision | Measured result |
| --- | --- |
| Neutrals given a blue-grey cast for "temperature contrast" | OKLCH chroma 0.019–0.026 across L 0.27–0.50 — the dusty-slate band |
| Brand chroma pulled in to avoid fatigue | 0.159, *below* the brief's own `#D9F14A` at 0.186 |
| Brand restricted to a single rare state | The identity colour was effectively never on screen |

For scale: Linear's surfaces sit at chroma 0.0042 and the brief's own 石墨黑
`#20242A` at 0.0127. Attempt 2's neutrals were **5× more chromatic than
Linear's and 2× more than the reference graphite.** Deleting the glow token
layer as "dead code" removed the last source of energy.

The lesson is specific and worth stating plainly: **desaturating everything is
not how you avoid fatigue.** Fatigue comes from large areas of saturated colour
and from vibrating pairs, not from vivid accents. Muting the accents while
also muddying the ground removes vibrancy and gains nothing.

### Core rules

1. **The ground stays clean; the accents stay vivid.** Neutrals are held at
   OKLCH chroma ≤ 0.013 so nothing hazes. Accents are generated at 88–100% of
   the maximum chroma sRGB allows at their lightness. A vivid accent only looks
   vivid against a clean ground.
2. **Concentrate saturated colour, do not ration it into invisibility.** Large
   flat fills stay neutral, but the brand appears at every structural landmark:
   active destination, send-ready control, own message, live activity.
3. **Five hues, globally.** Lemon 113°, soda cyan 207°, mint 157°, amber 72°,
   coral 25°. `info` is not a sixth hue; it belongs to the accent family.
4. **Lemon is never a text colour**, in either mode. Interactive text is always
   `accent` / `accentStrong`. This removes yellow-text fatigue in dark mode and
   the impossibility of legible pale lemon text in light mode, with one rule.
5. **`*Strong` means "more emphatic in the active mode."** In dark mode it is
   lighter; in light mode it is darker. Component code therefore reads correctly
   in both modes without branching on brightness.
6. **Brand and accent emit light.** `brandGlow` and `accentGlow` are real roles,
   not decoration. A brand landmark that glows reads as energetic; the same fill
   without a halo reads as flat.
7. **Tinted surfaces are computed washes, never hand-picked.** Hand-picking a
   dark lemon tint produced olive mud (`#2a2f12`, chroma 0.047). The wash is now
   a low-alpha blend of the accent over the neutral surface.

Built-in preset hex values are authored in
`apps/desktop/assets/appearance-presets/` and enforced by `theme_test.dart`.
Tables below summarize those files; if a value here diverges from the JSON, the
preset file wins.

### Palette — `lico-soda` (dark, default)

Generated from OKLCH targets, not chosen by eye. Chroma is quoted because it is
the property that was wrong before.

| Role | Token | Value | Chroma |
| --- | --- | --- | ---: |
| Inset well | `bg-inset` | `#040405` | 0.004 |
| Window | `bg-base` | `#0e0f12` | 0.007 |
| Content card | `bg-surface` | `#1c1c20` | 0.008 |
| Row / hover | `bg-subtle` | `#2a2a2f` | 0.009 |
| Popover | `bg-raised` | `#3a3a3f` | 0.009 |
| Hairline | `border-subtle` | `#323337` | 0.007 |
| Emphasis rim | `border-strong` | `#56565b` | 0.008 |
| Primary text | `text-primary` | `#f4f4f7` | 0.004 |
| Supporting text | `text-secondary` | `#cccdd0` | 0.004 |
| Metadata | `text-muted` | `#a6a7aa` | 0.004 |
| Disabled | `text-disabled` | `#6c6c70` | 0.006 |
| **Brand fill** | `brand` | `#e1ec28` | **0.194** |
| Brand emphatic | `brand-strong` | `#f3fe4f` | 0.189 |
| Brand wash | `brand-subtle` | `#2e2f21` | 0.024 |
| Brand hairline | `brand-border` | `#878d24` | 0.124 |
| Ink on brand | `text-on-brand` | `#171800` | — |
| **Interaction** | `accent` | `#21dcf1` | **0.137** |
| Interaction emphatic | `accent-strong` | `#87effe` | 0.099 |
| Interaction wash | `accent-surface` | `#1d3339` | 0.030 |
| Interaction rim | `accent-border` | `#1e838f` | 0.089 |
| Ink on accent | `text-on-accent` | `#00191e` | — |
| Success | `success` | `#2be18e` | 0.182 |
| Warning | `warning` | `#feae36` | 0.157 |
| Danger | `danger` | `#fb5f5b` | 0.192 |
| Hover wash | `hover-overlay` | `rgba(244, 244, 247, 0.07)` | — |
| Pressed wash | `pressed-overlay` | `rgba(244, 244, 247, 0.12)` | — |
| Brand halo | `brand-glow` | `rgba(225, 236, 40, 0.22)` | — |
| Interaction halo | `accent-glow` | `rgba(33, 220, 241, 0.26)` | — |

### Palette — `lico-soda-light` (light)

Same brand identity, same five hues. Accents darken because light backgrounds
demand it; the brand fill stays vivid and carries its mandatory hairline.

| Role | Value | Role | Value |
| --- | --- | --- | --- |
| `bg-inset` | `#dddde2` | `brand` | `#d9e320` |
| `bg-base` | `#eaebee` | `brand-strong` | `#878e1f` |
| `bg-surface` | `#ffffff` | `brand-subtle` | `#f5f8c5` |
| `bg-subtle` | `#f5f6f9` | `brand-border` | `#bfc744` |
| `bg-raised` | `#ffffff` | `text-on-brand` | `#1b1d00` |
| `border-subtle` | `#d1d2d8` | `accent` | `#007d8a` |
| `border-strong` | `#a6a7ae` | `accent-strong` | `#0d5f68` |
| `text-primary` | `#1a1a20` | `accent-surface` | `#deeef0` |
| `text-secondary` | `#4f4f55` | `accent-border` | `#67c8d6` |
| `text-muted` | `#68696f` | `text-on-accent` | `#ffffff` |
| `text-disabled` | `#9d9ea3` | `success` | `#158351` |
| `hover-overlay` | `rgba(26, 26, 32, 0.05)` | `warning` | `#9c660c` |
| `pressed-overlay` | `rgba(26, 26, 32, 0.09)` | `danger` | `#ce1828` |
| `brand-glow` | `rgba(217, 227, 32, 0.30)` | `accent-glow` | `rgba(0, 125, 138, 0.22)` |

`bg-raised` equals `bg-surface` in light mode by design: near white, tone has
almost no room left, so the top step is expressed with shadow instead.

### Enforced constraints

| Constraint | Threshold |
| --- | --- |
| Any text role on any surface it sits on | ≥ 4.5:1 |
| Ink on `brand` / `accent` | ≥ 4.5:1 |
| `accent` and `accentStrong` on `bg-surface` (used as link text) | ≥ 4.5:1 |
| `success` / `warning` / `danger` on `bg-surface` | ≥ 4.5:1 |
| `brandStrong` on `bg-surface` (non-text graphic, WCAG 1.4.11) | ≥ 3.0:1 |
| `brandBorder` on `bg-surface` (the mandated brand hairline) | ≥ 1.8:1 |
| `line` / `lineStrong` on `bg-surface` | ≥ 1.25:1 / ≥ 2.0:1 |
| Adjacent neutral surface steps | ≥ 3.0 ΔL\* |
| `brand` ≠ `accent`, `warning` ≠ `brand` | — |
| `default-system` brand hue, light vs dark | within 24° |
| **Neutral chroma** (every surface, border, secondary/muted text) | **≤ 0.013 OKLCH** |
| **Brand chroma** | **≥ 0.185** (the brief's `#D9F14A` = 0.186) |
| **Accent chroma** | **≥ 0.090** |
| Brand wash chroma | ≤ 0.030 dark / ≤ 0.075 light |
| Glow roles are translucent | 0 < alpha < 1 |

Surface separation is measured in **CIE L\***, not contrast ratio: contrast
ratio compresses badly near black and reports a clearly visible dark step as
"failing". Production dark systems step by roughly 2.3–7.4 L\*; 3.0 is the
floor.

Vibrancy is measured in **OKLCH chroma**, not HSL saturation, because HSL
reports near-black and near-white values as highly saturated and is therefore
useless for telling a clean neutral from a dusty one.

**A brand fill can be below 3:1 against its surface, and that is expected.**
A pale lemon fill on white cannot reach 3:1 without ceasing to be lemon. The
rule that follows is not optional: **a `brand` fill always carries a
`brandBorder` hairline**, and every lemon stroke, indicator, or mark uses
`brandStrong`.

## Color Roles

Consume roles from `LicoThemeColors` (`context.licoColors`). Layout profiles
consume the neutral projection `LayoutPalette` instead, because a profile must
not become an appearance authority; `verify-layout-boundaries` rejects any
`frontend/shared/ui/` import from the layout tree.

The theme→layout mapping exists in exactly one place,
`layoutPaletteFromColors()` in `lib/src/frontend/shell/layout_palette_projection.dart`.
Hand-writing a `LayoutPalette(...)` elsewhere is rejected by test: every
hand-enumerated site was a place a newly added role could be silently dropped,
and the test fixtures had already drifted that way.

### Where each role may be used

| Role | Fill | Border / mark | Glyph | Text |
| --- | :-: | :-: | :-: | :-: |
| `primary` (lemon) | yes | no | **never** | **never** |
| `primaryStrong` | yes | yes (≥3:1) | only on a brand fill | no |
| `textOnPrimary` | — | — | yes, on a brand fill | yes, on a brand fill |
| `accent` | yes | yes | **yes** | **yes** |
| `accentStrong` | yes | yes | yes | yes |
| `textSecondary` | — | — | yes (decorative) | yes |

Two consequences worth stating plainly:

- **A decorative icon is not a brand opportunity.** Colouring every settings row
  glyph is noise, not vibrancy, and lemon glyphs are illegible on a light
  surface. Decorative icons are `textSecondary`; interactive ones are `accent`.
- **Selected is not success.** A selection check mark uses `accent`, not
  `success`; using the semantic green put a third hue on a card that already
  carried a brand rim.

Brand presence comes from *fills at structural landmarks* — active destination,
send-ready control, own message, activity pulse — never from tinting glyphs.

### ColorScheme completeness

`ThemeData.colorScheme` must be constructed with every role set explicitly.
Never `copyWith` a Material baseline: the roles left unset keep Material's own
palette and leak into any widget that reaches for them. `surfaceTint` is
`transparent` because the neutral ramp already expresses elevation.

### Retired roles

`surfaceHigh`, `surfaceHighest`, `primaryFixed`, `info`, and `infoMuted` are
gone and are rejected by test. `surfaceHigh`/`surfaceHighest` were brand tints
posing as elevation steps — the direct cause of the client having no neutral
raised surface. `primaryFixed` duplicated `surfaceHigh`. `info` was already
doing the interaction job, so it became `accent`.

### State

Hover, pressed, and selected are **roles**, not locally invented alpha values.
`Colors.white.withAlpha(...)` and `Colors.black.withAlpha(...)` are rejected by
test inside `frontend/shared/ui/`, with three deliberate exemptions: the fixed
brand mark, the macOS system menu material, and the shadow scale. In the
feature layer the same rule is enforced as a ratchet: the existing wash count
is budgeted and may only shrink, so new invented washes fail the build.

That rule is not pedantry. Deriving fills from white alpha meant a custom light
preset received a white haze over its own background regardless of what it
declared, and it is why every control looked identical.

## Typography

Owned by `LicoTypography`. Two rules:

1. **Size and weight come from a role, never a literal.** Read
   `Theme.of(context).textTheme.*` or a helper. An inline
   `TextStyle(fontSize: 13.5)` is invisible to the scale.
2. **Numbers that change in place use tabular figures.** Proportional digits
   reflow as values update, which makes charts, token counters, byte sizes, and
   timestamps visibly jitter.

Scale steps by ≈1.2: 10 → 11 → 12 → 13 → 14 → 15 → 18 → 20 → 24 → 28 → 32.
Negative tracking on large sizes, positive on small.

| Role | Use |
| --- | --- |
| `displaySmall` | Brand moments only: empty states, onboarding, logo lockup |
| `headlineLarge/Medium/Small` | Page and section headings |
| `titleLarge/Medium/Small` | Card and group titles |
| `bodyLarge` | Conversation reading size, loosest line height in the scale |
| `bodyMedium` | Default UI copy |
| `bodySmall` | Metadata and captions |
| `labelLarge` | Buttons and emphasized labels |
| `labelMedium` / `labelSmall` | Dense labels and numbers (tabular) |
| `LicoTypography.eyebrow` | Small all-caps section label; adds structure without a heading level |
| `LicoTypography.metric` | Large monitoring values (tabular) |
| `LicoTypography.mono` | Paths, commands, ids, code (tabular) |

Monospace is semantic, not decorative: it marks text that is exact and
machine-meaningful, so the reader knows it is safe to copy verbatim.

Fonts are **bundled, never fetched.** See `apps/desktop/assets/fonts/README.md`.
The client currently uses the platform default with an explicit CJK fallback
chain; enabling Geist Sans/Mono is a two-line change that must land together
with the `pubspec.yaml` declaration.

## Surface and Depth

Three layers. Depth is a surface step, a hairline, and — only for genuinely
floating layers — a shadow.

| Layer | Surface | Rim | Shadow |
| --- | --- | --- | --- |
| **L0** window | `background` | none | none |
| **L1** content card | `surface` | `line` | only when standing off the window edge |
| **L2** floating | `surfaceRaised` | `line` | yes |
| **L3** modal | `surfaceRaised` | `line` | yes, deeper |

In the Messaging desktop profile, shell chrome (band, rail, and content-region
gutters) is a transparent native-blur layer with a shared glass tint — not an
opaque `background` fill. The `background` token still applies to filled content
inside the main card and to other profiles that paint the window directly.

Use `LicoSurface` with a `LicoSurfaceTone` and a `LicoElevation`. Tone answers
*what kind of thing this is*; elevation answers *how far forward it is*. Keeping
them independent stops a feature from expressing importance by inventing a
brighter fill.

Light mode carries more of the depth signal in shadow, dark mode more in tone,
because light-mode surface steps are compressed near white.

### Concentric corner radius

**Outer radius = inner radius + gap.**

When a rounded shape sits inside another with a uniform gap, their corners only
read as one continuous band if they share a center. Equal gaps with unrelated
radii make the band visibly thicken and thin around the curve.

This is computable, not advisory: use `LicoRadius.nested(outer, gap)` and
`LicoRadius.enclosing(inner, gap)`, and it is asserted in tests.

The composer previously violated it — a radius-15 circle inside a radius-8 field
with a 4px gap, where the nested radius should have been 4. That read as a foreign
part bolted into the input. The floating messaging composer now uses a **circular**
send control (`LicoIconButtonShape.circle`) as a deliberate accent inside the
rounded field capsule — not a concentric nested square at `LicoRadius.composerControl`.
Concentric nesting remains the rule for controls that must share the field's corner
band; the send affordance is an exception because brand fill and circular shape read
as the primary action, not as part of the field outline.

Current applications: window corner 24 = content card 16 + window margin 8;
the Dashboard folder sidebar card 16 inside an 8px margin; the macOS native
corner mask mirrors the same rule in `MainFlutterWindow.swift`.

## Window Chrome and Frosted Glass

The Messaging desktop layout profile uses native frosted glass for its shell
chrome. These rules are durable: any change to shell chrome must preserve them.

### Transparent window base

The bottom-most Flutter rendering layer must be **fully transparent** so the
platform can show live desktop blur beneath chrome regions and margin gutters.

On macOS, `apps/desktop/macos/Runner/MainFlutterWindow.swift` owns this:

- Window and `FlutterViewController` backgrounds are `.clear`; the window is
  non-opaque.
- An `NSVisualEffectView` with `.underWindowBackground` material sits behind
  the Flutter view. AppKit layer backgrounds are cleared (`isOpaque = false`,
  `backgroundColor = .clear`) on the effect view, Flutter view, and content
  view.
- Corner radius and `masksToBounds` are applied on the effect view; the Flutter
  view stays unclipped so transparent margin gutters do not expose a black
  backing layer.

Flutter shell code sets its scaffold base to `Colors.transparent` for the same
reason: opaque Flutter fills would hide the native blur.

### Unified glass on three shell regions

The top chrome band, left destination rail, and the content region beneath them
(the area to the right of the rail and below the band, including margin gutters
around the main card) must read as **one identical glass layer**. They share:

| Component | Role |
| --- | --- |
| `MessagingChromeBand` | Top tab/chrome bar: conversation tabs, search, notifications |
| `MessagingDestinationRail` | Left icon navigation rail |
| `MessagingContentRegion` | Remaining shell area under the band and right of the rail |
| `MessagingMainContentCard` | Shared outer content card (glass + black veil, border, shadow, radius via `mainContentCard*`) |

The rounded **main content card** (`MessagingMainContentCard`, key
`messaging-desktop-main-card`) sits on top of the content region as an L1
**glass card**: transparent glass over native VE, plus hairline border, soft
shadow, and shared corner radius. Shell code must build it through
`MessagingMainContentCard` — not inline decoration.

**Why a black veil on this card (not on shell chrome).** The conversation
surface is glass by design (transparent fill so native frosted blur shows
through). Dense chat and list text on that raw glass is hard to read — contrast
collapses against busy wallpaper blur. Therefore the main content card paints a
**black mask** (`Colors.black` via `mainContentCardFill` /
`mainContentCardOverlayDarkAlpha` / `mainContentCardOverlayLightAlpha`) to
raise text readability while keeping the glass character. Shell band / rail /
content-region gutters stay **untinted** (`surfaceGlassTint` → transparent):
they are chrome, not a reading surface, and a shell-wide Flutter tint muddies
the frosted material (see **Shared tint tokens** below).

Geometry and veil **must** come from `MessagingDesktopMetrics.mainContentCard*`
helpers — no hardcoding. No Flutter `BackdropFilter` on this card; blur remains
native VE beneath the transparent shell.

### Shared tint tokens — no hardcoding

Frosted blur comes from the native visual-effect view. Flutter chrome does
**not** apply a color tint overlay in either preset — shared tokens in
`MessagingDesktopMetrics` (`messaging_desktop_tokens.dart`) keep all three
regions on one path:

- `surfaceGlassTint(isDark:)` — the single entry point all three regions use;
  returns fully transparent in both presets
- `chromeTintDarkAlpha` — `0`; dark preset uses native VE only
- `lightSurfaceGlassAlpha` — `0`; light preset uses native VE only

**Why no Flutter tint overlay.** Stacking a Flutter color wash (especially
white in light mode, and black in dark mode) on top of the native
`NSVisualEffectView` severely degrades frosted-glass material quality — the
blur reads flat or muddy instead of translucent. Both presets therefore rely
on native frosted glass alone; chrome foreground tokens (icons, search, hover
washes) handle legibility without painting a shell-wide tint layer.

Do **not** hardcode per-component tint alphas or duplicate glass colors in
feature code. Do **not** use Flutter `BackdropFilter` on shell chrome as the
blur source: it samples the engine's black clear color and breaks the native
frosted effect.

Each region still implements the shared path as a `ColoredBox` using
`surfaceGlassTint` so call sites stay unified even when the tint is transparent.

### Light and dark glass parity

Light and dark presets must present **equivalent frosted-glass character**
through the same glass system — not a separate light-opaque or solid chrome
treatment. The shell should read as translucent blur in both modes; light mode
must not fall back to painting chrome as an opaque `background` fill while dark
mode keeps native frosted glass.

**Chrome backgrounds.** The three shell regions (`MessagingChromeBand`,
`MessagingDestinationRail`, `MessagingContentRegion`) use the same structure in
both presets: transparent window base and native blur beneath. Each region still
uses a `ColoredBox` from `surfaceGlassTint(isDark:)` so call sites stay
unified; in both presets that tint is fully transparent (no stacked white or
black layer). Token values live in `MessagingDesktopMetrics` — not per-widget.
The contract is that both presets deliver the same *glass* reading — visible
blur, consistent transparency treatment, one unified layer — with native
frosted material only.

**Chrome icons and controls.** Light and dark presets share the **same**
light-on-glass chrome style: clean white foreground for icons, search field
(icon, placeholder, thin border), bell, tabs, and related shell controls.
Visual character must stay **consistent** (一致) across presets — do not
introduce a divergent light-only or dark-only chrome icon treatment.

All chrome foreground colors and alphas **must** go through shared tokens in
`MessagingDesktopMetrics` (`chromeForegroundColor`, `chromeIconMuted`,
`chromeIconHover`, `chromeIconDisabled`, `chromeForeground`, `chromeSearchBorder`,
`chromeSearchIcon`, `chromeSearchPlaceholder`) — not raw palette roles
(`textMuted`, `text`, `line`) and not per-widget `isDark` branches or
hardcoded `Colors.white` / theme-specific one-offs. Widgets call the token
helpers only; token values live in one place.

Selected rail tiles and other brand-primary fills keep `textOnPrimary` (or
equivalent) on the fill for readable contrast. Unselected chrome icons follow
the shared light-on-glass foreground path in **both** presets. Do not introduce
opaque rail tiles or desaturated solid chrome buttons where the shared glass
system applies.

### Seamless shell edges

The band, rail, and content region form one continuous glass layer. Do **not**
draw hairline or border dividers along their shared edges (band↔rail,
rail↔content region, band↔content region). Separation comes from the main card
inset and internal content structure, not chrome edge rules.

### Enforcement

Shell chrome must stay token-driven. Adding a fourth glass region, changing
tint values, or adjusting chrome icon/search styling requires updating
`MessagingDesktopMetrics` once and keeping all consumers aligned. Chrome
foreground styling is **mandatory-consistency**: light and dark must share the
same token path and visual character; divergent per-theme hardcoding in widgets
is not allowed.

## Motion

Owned by `LicoMotion`. Inline `Duration(milliseconds: …)` is rejected by test
inside `frontend/shared/ui/`, and the feature layer is under a **ratchet**: the
remaining count may fall, never rise.

| Token | Value | Use |
| --- | --- | --- |
| `instant` | 0 | A change that must read as an immediate fact |
| `micro` | 120 ms | Hover, press, focus — must not feel laggy to click |
| `short` | 180 ms | Icon state change, badge pop, small crossfade |
| `medium` | 240 ms | Panel reveal, list entry, selection move |
| `long` | 400 ms | Full-surface transition, first-paint reveal |
| `loopShort` | 900 ms | One spinner sweep |
| `loopLong` | 1600 ms | One ambient loop: edge pulse, shimmer |

Curves: `standard`, `decelerate` (entering/growing), `accelerate`
(leaving/shrinking), `emphasized` (deliberate, weighted — a brand indicator
settling), `linear` (loops only; easing a loop makes the seam visible).

**Every animation routes through `context.motion(duration)`**, which returns
zero when the platform requests reduced motion. Continuous loops additionally
check `context.allowsAmbientMotion` and are replaced by a static state rather
than sped up, because a zero-duration repeating controller busy-spins the
ticker.

### Focus and activation, distinguished

- **Focus** is an interaction: a 2px `accent` ring. A one-pixel color change is
  not a reliable focus signal.
- **Brand activation** is identity: a `brandStrong` indicator over a
  `brandSurface` fill.

These never mix.

## Components

One recipe per job. The client previously carried five near-identical icon
buttons that read as unrelated controls.

| Primitive | Purpose |
| --- | --- |
| `LicoIconButton` | Every icon-only control. `size` × `shape` × `tone`. |
| `LicoSurface` | Every themed container. `tone` × `elevation`. |
| `LicoSkeleton` | Loading placeholders shaped like the incoming content. |
| `AppleGlassSurface` | Translucent material over live blurred content. |
| `AppleControlButtons` | Text-bearing button styles. |

`LicoIconButton` shape is not a free choice: a control nested inside a rounded
container must use `LicoIconButtonShape.concentric` and pass a radius from
`LicoRadius.nested`. The assertion fires at construction if the radius is
missing.

Tone `brand` is reserved for the single most important action in a view. Two
brand-tone buttons in one row is a defect.

### Loading

Use a **skeleton** when the shape of the result is known ahead of time —
conversation lists, agent rosters, charts, contact rows. Use a **spinner** only
for an action whose result has no shape, such as a running command.

Perceived speed is mostly a layout problem: a spinner in an empty pane tells
the user nothing and forces a second reflow when content lands.

## Content Rhythm and Spacing

`LicoContentSpacing` is the canonical scale. Feature code must not invent
adjacent-item gaps.

| Token | Value | Use |
| --- | ---: | --- |
| `inline` | 4 px | Closely related inline details |
| `compact` | 8 px | Elements inside one card, bubble, row, or control |
| `item` | 16 px | Peer messages, cards, process items, logs, notices |
| `section` | 24 px | Separate content groups |

Two adjacent peer items must never touch. `compact` is only for elements
belonging to the same component; it must not squeeze separate timeline items
together.

## Text Selection and Copy

**Conversation text is selectable and copyable.** This was previously not true
anywhere in the conversation surface.

`SelectionArea` hosts selection at the transcript scroll level so a drag can
span several messages. Because a `ListView` only builds visible rows, selection
cannot reach off-screen messages, so individual messages must also expose an
explicit copy action — the two mechanisms are complementary, not redundant.

Chrome that would pollute a selection opts out with
`SelectionContainer.disabled`: process disclosure rows and log rows.
Interactive disclosures in particular must keep their
expand/collapse activation, which a drag-select would otherwise swallow.

Paths, error codes, PIDs, session ids, and diagnostic fields use
`SelectableText`.

## Navigation

Desktop first-level destinations live in a left icon rail on the unified
frosted-glass shell — no rail card, no labels, no collapse chrome, and no edge
divider separating the rail from the band or content region. The rail, the
transparent top band, and the content region beneath them share one frosted
glass treatment (see **Window Chrome and Frosted Glass**); macOS traffic lights
overlay the rail's top clearance.

Content stacks in three flat layers: transparent window base with native blur,
one unified-glass shell (rail, top band, and margin gutters), then the rounded
main content card standing off the trailing and bottom edges, and the
destination detail as the innermost layer.

Mobile keeps a compact Agents/Settings shell; pairing and encrypted relay flows
open contextually.

## Messages Profile

Messages exists so a person treats LicoUp as a messaging client and, from
there, as the entry point to every agent on the machine. The transcript
therefore follows chat-client convention rather than tool convention.

**Author treatment is asymmetric.** The user's own message is a right-aligned
frosted-glass bubble: fully transparent fill, shared overlay blur sigma, and a
**neutral** `line` hairline — via `MessagingDesktopMetrics.userBubbleGlass*` /
`MessagingUserBubbleGlass`. Do **not** use `brandBorder`, `primary`, or lemon
edge glow on transcript bubbles or AGENT badges; those read as olive 泛黄 on
the dark glass canvas. An agent reply sits flush on the surface on the
**left**. Group headers show an **author avatar** (brand mark for agents via
`MessagingAgentAvatar`, `person_outline` for the user) plus display name and a
neutral AGENT / role chip on `surfaceLow` + `line` — never brand wash. Both
authors pick up shared `hoverOverlay` on row hover; each message reveals its
timestamp on hover **outside** the bubble at bottom-right, with reserved space
so the row does not jump. Group headers carry author identity only (no clock).

Consecutive messages from one author are a headerless continuation. Group
internal gap is `compact`; between groups it is `item`.

**Process disclosure (single-turn Working).** Structured process runs render as
`MessagingProcessStatusRow` inline under the triggering user message in the
participant flow, **full width of the transcript column** (same horizontal span
as agent content — not a shrink-wrapped chip). While a turn is active the row
uses shared overlay-glass wash with a **neutral** `line` border (never
`primary`/lemon), a muted spinner, a soft neutral top-edge pulse, and
auto-expands the shared operation list. The latest redacted step headline stays
visible when the user collapses the list. The five-stage lifecycle rail uses
neutral `text`/`line` accents (not brand lemon) and appears only before the
first structured operation arrives; once tool/reasoning steps stream in, the
operation list owns live feedback. Completed turns collapse to a muted duration
+ step-count summary. Subagent cards in the messaging flow are also full-width.

**Composer runtime context (Messages).** Model, reasoning effort, and working
directory are secondary to the transcript. On Messaging desktop they live in the
composer **context capsule row** immediately above the input field — not in a
persistent settings band and not only behind a buried overflow menu. Dashboard
may still surface the same facts more visibly via `showRuntimeSettings`.

**Agents workspace framing (Telegram-style).** The Messaging desktop Agents
destination sits inside the shell **main content glass card**
(`MessagingMainContentCard`). Inside that card, a two-column split shares the
card's glass as the conversation background:

| Region | Treatment |
| --- | --- |
| **Main content card** | Transparent glass + **black veil** for readability (border, shadow, radius via `mainContentCard*`). |
| **Chat canvas** (workspace fill) | **Transparent** — lets the main content card (glass + veil) show through behind both columns. |
| **Left conversation list** | Nested **floating glass card** above that background (`conversationListCard*`). |
| **Right conversation detail** | **Flush with the main-card surface** (一体) — no detail-column card chrome. |
| **Chrome conversation tabs** | The top band lists live conversation targets from `orderedConversationTargets`, including the synthetic orchestration contact labeled **默认** / Default. Tabs switch agent context without inventing a separate “home” chrome recipe. |
| **Conversation header** | Left: adaptive-width identity glass **capsule**; right: separate capsule icon buttons at the **same height and corner radius** as the identity capsule, with shared gap. Capsules **overlay** the full-height transcript (`Stack` + `conversationHeaderOverlayExtent` top inset) so the detail canvas is continuous — not a Column band that truncates the chat below. Geometry via `conversationHeaderCapsule*`; glass via shared `MessagingConversationOverlayGlass` / `conversationOverlayGlass*`. **Header icon actions** (conversation switcher, details) and the chrome-band **notification bell** open as **hover-revealed floating cards** anchored to their triggers — not push sidebars or opaque menus. Cards share `MessagingHoverPopover` + `MessagingConversationOverlayGlass` with the notification readability veil; tap toggles for accessibility. The popover follower **shrink-wraps the card** so `targetAnchor` / `followerAnchor` resolve against the card size (top-right triggers keep `bottomRight`/`topRight`; composer runtime uses `topLeft`/`bottomLeft`). Details content (runtime, capabilities, connection, session metadata) lives in the details hover card on desktop and a bottom sheet on mobile — there is no details sidebar. |
| **Conversation composer** | Same overlay model and **the same overlay-glass treatment** as the header capsules (shared `MessagingConversationOverlayGlass` + `conversationOverlayGlass*` fill/border/blur/shadow — white wash family, not a heavier black slab). Floats over the transcript with `conversationComposerOverlayExtent` bottom inset. Messaging desktop adds a **separate attach capsule** immediately to the left of the input capsule (same square extent and corner radius as header icon buttons via `conversationHeaderCapsuleButtonExtent` / `conversationComposerCapsuleCornerRadius`; gap via `conversationHeaderCapsuleButtonGap`). The attach control is outside the input field, not embedded inside it. Send is a **circular** brand-accent control trailing the field capsule. A **context capsule row** (`ComposerCapsuleRow`) sits directly above the composer on messaging surfaces: workspace directory (folder / `~/…` / lock) and a **runtime selector capsule** (`ComposerRuntimeCapsule`) share one glass band and `conversationComposerCapsuleRowExtent` transcript inset. The runtime capsule shows a compact **model + reasoning-effort** summary with a chevron (empty model selection displays the localized **Auto** / native-default label). Hover or tap opens a frosted primary glass card whose **sibling rows** are **模型 / Model** and **思考强度 / Reasoning Effort** when that agent exposes effort options for the effective model (explicit selection, else catalog default). Each row cascades into its own detached submenu to the right with a gap; the primary card stays fixed (`CrossAxisAlignment.end` so a tall submenu does not lift the primary off the capsule). The Model submenu marks the catalog default as Auto/default; the Effort submenu offers a leading Auto row to clear an override. Hide empty rows and hide the whole runtime capsule when no selectable catalogs exist. Console may keep model/effort selection inside a denser runtime bar. |

**Black veil rationale.** Conversation UI is a transparent glass card on native
frosted blur. Without a darkening layer, message and list text lose contrast.
The black mask is therefore required on the main content card for legibility;
it is **not** reapplied to shell navigation chrome.

Hard rules:

1. Do **not** wrap list + chat in a *second* shared glass card inside the main
   card; the main card already is that shared glass surface.
2. Do **not** give the detail column its own floating card chrome.
3. Do **not** use Flutter `BackdropFilter` on the main/list interior cards
   (crisp wash only; shell blur remains native VE — see **Window Chrome and
   Frosted Glass**). Conversation **header/composer overlay capsules** and
   **user message bubbles** are exceptions: capsules share
   `MessagingConversationOverlayGlass` / `conversationOverlayGlass*`; own-
   message bubbles use `MessagingUserBubbleGlass` / `userBubbleGlass*`.
4. Main-card and list-card geometry/veil **must** come from shared
   `MessagingDesktopMetrics` helpers (`mainContentCardFill` /
   `mainContentCardBorder` / `mainContentCardShadows`, and
   `conversationListCard*`). Presentation and shell widgets must not hardcode
   inset, radius, tint, border, or shadow values for these cards.
5. Do **not** remove the main-card black veil without a replacement that keeps
   chat/list text readable on glass.
6. Do **not** let `MessagingHoverPopover` followers take tight full-screen
   overlay constraints without an `Align` (or equivalent) shrink-wrap — otherwise
   `followerAnchor` resolves against the window and top-right cards appear at
   the lower left.
7. Do **not** paint brand/primary wash on user bubbles, AGENT chips, Working
   rows, or lifecycle rails; transcript chrome stays neutral on glass.

**Shared main-card destinations.** Skill Center, Plugin Management, Token usage
statistics, Keys, Settings, and Mobile Relay use the same outer
`MessagingMainContentCard` container with a transparent destination canvas
(`messagingMainContentCardDestinations` in
`messaging_desktop_destination_presentations.dart`). They do **not** inherit
Agents-specific inner framing (nested list card, overlay header/composer).

Implementation ownership: shared outer card in
`messaging_main_content_card.dart` (used by `messaging_desktop_shell.dart`);
Agents framing in `MessagingDesktopAgentsPresentation`
(`messaging_desktop_destination_presentations.dart`); tokens in
`messaging_desktop_tokens.dart`; shared header/composer overlay glass in
`messaging_conversation_overlay_glass.dart`; user bubble glass in
`messaging_user_bubble_glass.dart`.

## Dashboard Profile

Dashboard is the developer layout. It should carry agent runtime monitoring,
assistive tooling, and later project management and file preview/editing.

### Panel contract

Any new Dashboard pane satisfies this anatomy so the layout does not fragment
as panes are added:

1. **Title band** — destination name, one-line state, primary action.
2. **Toolbar** — filters, window controls, refresh. Icon-only controls carry
   tooltips.
3. **Body** — the pane's content at one of two densities: `compact` for tabular
   or roster data, `comfortable` for reading and forms.
4. **Status foot** — last-updated time, counts, degraded-state notice. Never a
   place for raw command output.

Every pane declares four states: populated, empty, loading (skeleton), and
degraded/failed. A pane with no empty state is incomplete.

### Monitoring destination

`ClientSection.monitoring` already exists but renders only token usage, while
per-agent runtime facts (`running`, per-PID `rssBytes`, disk I/O, from
`licoup resource-usage scan`) sit unused as a card inside Settings. Settings is
not a registry for business modules.

Target information architecture, priority-ordered:

1. **Live band** — running agents, in-flight turns, aggregate RSS, client's own
   footprint. Compact metric tiles with sparklines; `LicoTopEdgePulse` while a
   turn is in flight.
2. **Agent roster** — one row per agent: brand icon, running/idle/blocked chip,
   process count, proportional RSS bar, disk I/O, last activity, 24h token
   burn. Expandable to per-PID rows.
3. **Trend band** — stacked usage chart, model share, time-window control.

Messages renders a condensed form (live band plus token trend) through the
existing destination-presentation port, so one destination serves two densities.

## Charts

Series color comes from a token-derived ramp seeded by the five palette hues and
ordered by perceptual distinctness. A hardcoded external ramp does not belong to
the palette and will clash with it.

- Axis labels and value readouts use a tabular numeric role.
- Grid lines are graded from `line`.
- Hover shows a crosshair plus a readout on `surfaceRaised`.
- Charts declare empty, insufficient-data, and loading states. A chart rendering
  a single baseline is an unhandled empty state.
- Wrap chart painters and long-list rows in `RepaintBoundary`.

## Notifications and Operation Feedback

The top-right notification center is the single destination for user-visible
notifications. Success, warning, failure, background-task, and asynchronous
operation feedback all enter that shared model. Feature pages must not create
their own snack bars, toasts, or duplicate status banners for the same event.

Pre-action confirmation stays in a modal dialog. Correctable, field-specific
validation stays beside its field. After an action starts, its completion or
failure belongs in the notification center even if the user navigated away.

Notifications use a stable event identity so refreshes do not duplicate them,
and expose a localized summary plus a safe error code. Raw command output, local
paths, credentials, and runtime details stay out of the presentation layer.

The messaging chrome notification bell, in-chat conversation switcher, and
details control each open a **hover-revealed floating card** anchored to the
trigger. All three reuse `MessagingHoverPopover` for pointer enter/leave grace
and optional tap pin, and `MessagingConversationOverlayGlass` for frosted
glass plus the modest black readability veil (`notificationPopoverVeil*`
layered under the glass wash) with `AppleControlMetrics.menuCornerRadius`.
Empty and populated states keep `textMuted` / `text` foreground tokens for
legibility on the veiled glass. Do not introduce alternate card recipes for
these controls, and do not restore a push sidebar for conversation details.

## Send Availability

Readiness is fail-closed. When an adapter is not yet send-ready, the composer
is a designed unavailable state: it states what is possible now (browsing
native history), what is missing (live parity or binding evidence), and the
next action. When an adapter is send-ready, the same composer chrome stays in
place — attach capsule, circular send, workspace capsule, and runtime capsule —
so availability never invents a second visual language.

Detection and history remain visually distinct from permission to send.

## Accessibility

- Contrast, surface separation, and role separation are enforced by
  `theme_test.dart` across both presets. Thresholds are listed above.
- Every animation honours the platform reduced-motion setting through
  `context.motion`.
- All command buttons, lists, and dialogs are keyboard navigable.
- Icon-only controls require tooltips.
- Readiness states such as ready, blocked, and unverified require visible text
  labels and never rely on color alone.
- Long paths, command output, and config previews wrap or scroll without
  obscuring adjacent controls.
