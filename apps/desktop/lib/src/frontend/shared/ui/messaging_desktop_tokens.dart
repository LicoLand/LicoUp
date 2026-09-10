import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/shared/ui/lico_content_spacing.dart';

/// Shared renderer measurements for the Messaging presentation.
abstract final class MessagingDesktopMetrics {
  /// Far-left destination column on the unified clear-veil shell.
  static const double navigationRailExtent = 56;

  /// Default width of the shared sidebar column on first open (no persisted
  /// pane extent). The shell column owns the user-draggable width; destination
  /// lists do not. 224 is the existing layout width step also used by
  /// [composerRuntimeSelectorPrimaryWidth].
  static const double conversationListExtent = 224;

  /// Narrowest usable shared sidebar column.
  static const double conversationListMinExtent = 196;

  /// Widest shared sidebar column.
  static const double conversationListMaxExtent = 420;

  /// Drag-handle hit target on the shared sidebar column.
  static const double conversationListDividerWidth = 8;

  /// Minimum remaining width for the detail pane when the column grows.
  static const double conversationDetailMinExtent = 360;

  /// Inset of the floating conversation-list glass card within the main
  /// content region — the card floats 4 inside the region (6 from the window
  /// edge), keeping a visible glass gutter around the one floating card.
  static const double conversationListCardInset = 4;

  /// Inner radius of the floating conversation-list glass card — concentric
  /// with the region clip: [mainCardCornerRadius] − [conversationListCardInset]
  /// = 20 − 4 = 16.
  static const double conversationListCardCornerRadius = 16;

  /// Translucent card fill on the dark chat canvas — thin enough that the
  /// window veil reads through instead of stacking into a gray haze.
  static const int conversationListCardTintDarkAlpha = 12;

  /// Translucent card fill on the light chat canvas.
  static const int conversationListCardTintLightAlpha = 92;

  /// Hairline border alpha on the floating list card (dark canvas).
  static const int conversationListCardBorderAlphaDark = 90;

  /// Hairline border alpha on the floating list card (light canvas).
  static const int conversationListCardBorderAlphaLight = 120;

  /// Drop-shadow alpha on the floating list card (dark canvas).
  static const int conversationListCardShadowAlphaDark = 60;

  /// Drop-shadow alpha on the floating list card (light canvas).
  static const int conversationListCardShadowAlphaLight = 20;

  /// Drop-shadow blur of the floating list card.
  static const double conversationListCardShadowBlur = 16;

  /// Drop-shadow Y offset of the floating list card.
  static const double conversationListCardShadowOffsetY = 4;

  /// One circular identity size across conversation chrome: the header
  /// capsule identity icons, message author avatars, and the floating
  /// group-member roster all render at this extent.
  static const double conversationAvatarExtent = 40;

  /// Glyph size inside a [conversationAvatarExtent] identity circle.
  static const double conversationAvatarMarkExtent = 22;

  /// Assistant control inside the composer field capsule: circular extent and
  /// its mark size (smaller than the avatar family; it lives inside the
  /// field's text row). The extent slightly exceeds the single-line text row
  /// so the control keeps equal frame insets on top, bottom, and left.
  static const double conversationComposerAssistantExtent = 32;
  static const double conversationComposerAssistantMarkExtent = 16;

  /// Empty bands between the group roster and the floating header/composer.
  static const double groupRosterHeaderGap = 10;
  static const double groupRosterComposerGap = 10;

  /// Detached member capsule in the right transcript band: a slim stadium
  /// hugging the member avatars with [groupRosterPadH] on each side.
  static const double groupRosterPadH = 4;
  static const double groupRosterExtent =
      conversationAvatarExtent + groupRosterPadH * 2;
  static const double groupRosterScrollbarThickness = 2;
  static const double groupRosterMinimumVisibleExtent = 128;
  static const int groupRosterVisibleMemberCount = 5;

  /// Bare avatar row height after member names moved into tooltips — the
  /// shared conversation avatar size.
  static const double groupRosterMemberExtent = conversationAvatarExtent;

  /// Provider-quota ring painted around a roster avatar inside the existing
  /// [groupRosterMemberExtent]: the avatar insets by the ring band so the
  /// capsule silhouette and member extent stay unchanged.
  static const double groupRosterQuotaRingThickness = 2;
  static const double groupRosterQuotaRingInset = 1;
  static const double groupRosterQuotaAvatarExtent =
      groupRosterMemberExtent -
      (groupRosterQuotaRingThickness + groupRosterQuotaRingInset) * 2;
  static const double groupRosterQuotaAvatarMarkExtent = 18;

  /// Stale snapshots paint the same arc dimmed at this alpha (of 255).
  static const int groupRosterQuotaRingStaleAlpha = 96;

  /// Hover quota-card progress bar: a full-width stadium track with a
  /// severity-colored fill, one per quota window.
  static const double quotaCardBarHeight = 6;
  static const double quotaCardBarGapAbove = 3;
  static const double quotaCardBarGapBelow = 3;

  /// Stale snapshots paint the bar fill dimmed at this alpha (of 255).
  static const int quotaCardBarStaleAlpha = 96;

  static const double groupRosterMemberGap = 5;
  static const double groupRosterVerticalInset = 5;
  static const double groupRosterMaxVisibleExtent =
      groupRosterVisibleMemberCount * groupRosterMemberExtent +
      (groupRosterVisibleMemberCount - 1) * groupRosterMemberGap +
      groupRosterVerticalInset * 2;

  /// Horizontal inset of the floating conversation-header capsule.
  static const double conversationHeaderCapsuleInsetH = 12;

  /// Vertical inset of the floating conversation-header capsule.
  static const double conversationHeaderCapsuleInsetV = 8;

  /// Shared radius of the capsule family outside the header identity
  /// capsules (composer capsule, group failure alert). Header identity
  /// capsules and the group roster surface use a full stadium instead — see
  /// their call sites (`BorderRadius.circular(999)`).
  static const double conversationHeaderCapsuleCornerRadius = 22;

  /// Inner horizontal padding inside the header capsule.
  static const double conversationHeaderCapsulePadH = 12;

  /// Inner vertical padding inside the header capsule.
  static const double conversationHeaderCapsulePadV = 8;

  /// Square extent of trailing header capsule icon buttons.
  static const double conversationHeaderCapsuleButtonExtent = 36;

  /// Gap between trailing header capsule buttons.
  static const double conversationHeaderCapsuleButtonGap = 8;

  /// Vertical space reserved under the floating header capsules so the
  /// transcript can scroll beneath them without clipping the first rows.
  /// insetV×2 + padV×2 + avatar.
  static const double conversationHeaderOverlayExtent =
      conversationHeaderCapsuleInsetV * 2 +
      conversationHeaderCapsulePadV * 2 +
      conversationAvatarExtent;

  /// Extra gap between the header overlay and the group failure alert.
  static const double conversationFailureAlertGap = 16;

  /// Horizontal inset of the floating composer capsule.
  static const double conversationComposerCapsuleInsetH = 12;

  /// Vertical inset of the floating composer capsule from the bottom edge.
  static const double conversationComposerCapsuleInsetV = 10;

  /// Corner radius of the floating composer capsule (matches header capsule).
  static const double conversationComposerCapsuleCornerRadius =
      conversationHeaderCapsuleCornerRadius;

  /// Shared BackdropFilter sigma for conversation overlay glass (header
  /// capsules + floating composer). One value — keep header and input matched.
  /// Kept low so the glass reads clear （清透） rather than frosted.
  static const double conversationOverlayGlassBlurSigma = 12;

  /// Approximate height reserved under the floating composer so the
  /// transcript clears it (padding + field + send row).
  static const double conversationComposerOverlayExtent = 78;

  /// Extra transcript clearance when context capsules (workspace, model, …)
  /// sit above the floating composer.
  static const double conversationComposerCapsuleRowExtent = 40;

  /// Circular jump-to-latest control above the floating composer.
  static const double conversationScrollToLatestExtent = 36;

  /// Gap between the jump-to-latest control and the composer overlay.
  static const double conversationScrollToLatestGap = 8;

  /// Deprecated alias — use [conversationComposerCapsuleRowExtent].
  static const double conversationComposerWorkspaceChipExtent =
      conversationComposerCapsuleRowExtent;

  /// Primary column width for the composer runtime selector. Wide enough to
  /// keep the longest control name (Reasoning Effort) on one line beside its
  /// current value.
  static const double composerRuntimeSelectorPrimaryWidth = 224;

  /// Submenu column width for model / effort option lists. Wide enough to
  /// keep fused Cursor-style labels readable without truncating them into
  /// indistinguishable prefixes.
  static const double composerRuntimeSelectorSubmenuWidth = 320;

  /// Gap between the fixed primary runtime card and the detached submenu card.
  static const double composerRuntimeSelectorSubmenuGap = 8;

  /// Max width of the runtime selector hover popover (primary + gap + submenu).
  static const double composerRuntimeSelectorPopoverMaxWidth =
      composerRuntimeSelectorPrimaryWidth +
      composerRuntimeSelectorSubmenuGap +
      composerRuntimeSelectorSubmenuWidth;

  /// Max height of the runtime selector hover popover (primary ± submenu).
  static const double composerRuntimeSelectorPopoverMaxHeight = 260;

  /// Max height of composer-adjacent option menus.
  static const double composerOptionPopoverMaxHeight = 360;

  /// Max height of the bounded, scrollable runtime selector submenu.
  static const double composerRuntimeSelectorSubmenuMaxHeight = 220;

  /// Shared overlay-glass fill for header capsules and composer — same wash
  /// family as the conversation-list card (not a heavier black slab).
  static Color conversationOverlayGlassFill({required bool isDark}) =>
      conversationListCardFill(isDark: isDark);

  /// Shared overlay-glass border on [line].
  static Color conversationOverlayGlassBorder(
    Color line, {
    required bool isDark,
  }) => conversationListCardBorder(line, isDark: isDark);

  /// Shared overlay-glass elevation shadow.
  static List<BoxShadow> conversationOverlayGlassShadows({
    required bool isDark,
  }) => conversationListCardShadows(isDark: isDark);

  /// BackdropFilter sigma for user message bubbles — same family as overlay
  /// glass so header, composer, and own-message bubbles feel matched.
  static const double userBubbleGlassBlurSigma =
      conversationOverlayGlassBlurSigma;

  /// User bubble interior fill — always fully transparent. Do **not** tint
  /// with brand/primary: even low brand alphas read as olive “底色”, and a
  /// brand-colored layer under BackdropFilter frosts yellow into the pill.
  static const int userBubbleGlassFillDarkAlpha = 0;

  /// Light-canvas counterpart — also fully transparent.
  static const int userBubbleGlassFillLightAlpha = 0;

  /// Neutral transparent fill for user message bubbles.
  static Color userBubbleGlassFill({required bool isDark}) =>
      Colors.transparent.withAlpha(
        isDark ? userBubbleGlassFillDarkAlpha : userBubbleGlassFillLightAlpha,
      );

  /// Accent edge-light shared by conversation bubbles — Kiro-style: a thin,
  /// bright rim line plus a light field that decays outward from the rim.
  /// Interiors stay dark glass. Never brand/primary — lemon rims read as
  /// olive 泛黄 on the dark chat canvas.
  ///
  /// The light is stroked around the rounded rim by
  /// `MessagingBubbleEdgeGlowPainter` as bloom: crisp rim plus gaussian
  /// passes whose blur grows while alpha falls. A gradient band painted
  /// under an inset fill bleeds through translucent glass, and a radial tint
  /// clamps to its edge color past the gradient radius and floods wide
  /// bubbles.
  static const double bubbleEdgeRimWidth = 1;

  /// Rim line alpha at the top edge (dark canvas) — thin and bright.
  static const int bubbleEdgeGlowAlphaDark = 245;

  /// Rim line alpha at the top edge (light canvas).
  static const int bubbleEdgeGlowAlphaLight = 210;

  /// Rim line alpha at the bottom edge (dark canvas).
  static const int bubbleEdgeGlowDimAlphaDark = 120;

  /// Rim line alpha at the bottom edge (light canvas).
  static const int bubbleEdgeGlowDimAlphaLight = 105;

  /// Near field alpha (dark canvas): the bright glow hugging the line.
  static const int bubbleEdgeGlowNearAlphaDark = 160;

  /// Near field alpha (light canvas).
  static const int bubbleEdgeGlowNearAlphaLight = 132;

  /// Mid field alpha (dark canvas): the first outward decay step.
  static const int bubbleEdgeGlowMidAlphaDark = 115;

  /// Mid field alpha (light canvas).
  static const int bubbleEdgeGlowMidAlphaLight = 95;

  /// Far field alpha (dark canvas): the wide lamp-light cast.
  static const int bubbleEdgeGlowFarAlphaDark = 70;

  /// Far field alpha (light canvas).
  static const int bubbleEdgeGlowFarAlphaLight = 58;

  /// Rim-light band: brightest along the top edge, calm at the bottom.
  static Gradient bubbleEdgeGlowBand(
    Color accentGlow, {
    required bool isDark,
  }) => LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [
      accentGlow.withAlpha(
        isDark ? bubbleEdgeGlowAlphaDark : bubbleEdgeGlowAlphaLight,
      ),
      accentGlow.withAlpha(
        isDark ? bubbleEdgeGlowDimAlphaDark : bubbleEdgeGlowDimAlphaLight,
      ),
    ],
  );

  /// Distance-decay field gradient for one glow pass: the rim hue at [alpha]
  /// on the top edge, fading toward the bottom. Painted by the rim painter
  /// (outward-clipped) instead of a `boxShadow`: a shadow's blurred
  /// silhouette fills the whole box and would wash the translucent interior.
  static Gradient bubbleEdgeGlowAura(Color accentGlow, {required int alpha}) =>
      LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          accentGlow.withAlpha(alpha),
          accentGlow.withAlpha((alpha * 0.45).round()),
        ],
      );

  /// Agent bubble interior: the shared black readability veil, not an accent
  /// tint — the accent lives only on the rim light.
  static Color agentBubbleVeilFill({required bool isDark}) =>
      conversationOverlayReadabilityVeilFill(isDark: isDark);

  /// Resting (unlit) neutral hairline on conversation bubbles — the plain
  /// style the hover-lit edge light fades back to.
  static Color bubbleRestingBorder(Color line, {required bool isDark}) =>
      line.withAlpha(isDark ? 90 : 100);

  /// Black readability veil on floating conversation overlays (dark).
  /// Layered with [conversationOverlayGlassFill] and blur so menus and
  /// popovers remain distinct from live content without becoming opaque.
  /// Thinner than the original frosted recipe — the clear-glass direction
  /// keeps the veil minimal and lets the blur do the separation work.
  static const int conversationOverlayReadabilityVeilDarkAlpha = 60;

  /// Lighter counterpart for floating overlays on the light preset.
  static const int conversationOverlayReadabilityVeilLightAlpha = 28;

  /// Shared black readability veil for floating conversation overlays — use
  /// with overlay glass, not as a standalone opaque panel.
  static Color conversationOverlayReadabilityVeilFill({required bool isDark}) =>
      Color.fromARGB(
        isDark
            ? conversationOverlayReadabilityVeilDarkAlpha
            : conversationOverlayReadabilityVeilLightAlpha,
        0,
        0,
        0,
      );

  /// Fill wash for the floating conversation-list card. Widgets must use this
  /// helper (or the named alphas above) — do not hardcode tint alphas in
  /// presentation code.
  static Color conversationListCardFill({required bool isDark}) =>
      Color.fromARGB(
        isDark
            ? conversationListCardTintDarkAlpha
            : conversationListCardTintLightAlpha,
        255,
        255,
        255,
      );

  /// Header capsule fill — aliases the shared conversation overlay glass.
  static Color conversationHeaderCapsuleFill({required bool isDark}) =>
      conversationOverlayGlassFill(isDark: isDark);

  /// Header capsule border — aliases the shared conversation overlay glass.
  static Color conversationHeaderCapsuleBorder(
    Color line, {
    required bool isDark,
  }) => conversationOverlayGlassBorder(line, isDark: isDark);

  /// Header capsule shadow — aliases the shared conversation overlay glass.
  static List<BoxShadow> conversationHeaderCapsuleShadows({
    required bool isDark,
  }) => conversationOverlayGlassShadows(isDark: isDark);

  /// Border color for the floating conversation-list card on [line].
  static Color conversationListCardBorder(Color line, {required bool isDark}) =>
      line.withAlpha(
        isDark
            ? conversationListCardBorderAlphaDark
            : conversationListCardBorderAlphaLight,
      );

  /// Elevation shadow for the floating conversation-list card.
  static List<BoxShadow> conversationListCardShadows({required bool isDark}) =>
      [
        BoxShadow(
          color: Color.fromARGB(
            isDark
                ? conversationListCardShadowAlphaDark
                : conversationListCardShadowAlphaLight,
            0,
            0,
            0,
          ),
          blurRadius: conversationListCardShadowBlur,
          offset: const Offset(0, conversationListCardShadowOffsetY),
        ),
      ];

  /// Specular edge light for clear-glass surfaces: one uniform rim around
  /// the full frame, plus a soft sheen band decaying downward from the top.
  /// The light is [chromeForegroundColor] — the same preset-independent
  /// light the shell chrome already uses — never brand/primary, so the rim
  /// reads as reflected light instead of a colored outline. Painted by
  /// `GlassEdgeLight`; shells must use these tokens, not hardcoded alphas.
  static const double glassEdgeRimWidth = 1;

  /// Rim alpha on every edge (dark canvas). Same value all the way around
  /// so the frame does not fade from top to bottom.
  static const int glassEdgeRimAlphaDark = 110;

  /// Rim alpha on every edge (light canvas).
  static const int glassEdgeRimAlphaLight = 185;

  /// Top sheen band alpha (dark canvas) — a faint glint; brighter bands read
  /// as a painted highlight instead of reflected light.
  static const int glassEdgeSheenAlphaDark = 10;

  /// Top sheen band alpha (light canvas).
  static const int glassEdgeSheenAlphaLight = 16;

  /// Height of the top sheen band on structural cards (main card, floating
  /// list card). Small capsules pass a tighter extent.
  static const double glassEdgeSheenExtent = 56;

  /// Uniform rim color for the full glass frame.
  static Color glassEdgeRimColor({required bool isDark}) =>
      chromeForegroundColor.withAlpha(
        isDark ? glassEdgeRimAlphaDark : glassEdgeRimAlphaLight,
      );

  /// Sheen gradient for the top band: the rim hue fading to nothing.
  static Gradient glassEdgeSheenGradient({required bool isDark}) =>
      LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          chromeForegroundColor.withAlpha(
            isDark ? glassEdgeSheenAlphaDark : glassEdgeSheenAlphaLight,
          ),
          chromeForegroundColor.withAlpha(0),
        ],
      );

  /// Window inset of the unified content region on every edge. Narrow (4) by
  /// design: destinations sit nearly flush with the window frame so the
  /// region merges into the window glass and only the sidebar card reads as
  /// floating (macOS split-view idiom).
  static const double mainCardMargin = 4;

  /// Page inset inside the unified main content region. Every single-pane
  /// destination (Settings, Models, Skill Hub, Plugins, Monitoring, Mobile
  /// Relay) uses this same padding so content does not hug the region chrome.
  static const EdgeInsets mainPanePadding = EdgeInsets.fromLTRB(24, 20, 24, 40);

  /// Outer corner radius of the unified content region's clip — concentric
  /// with the window: [windowCornerRadius] − [mainCardMargin] = 24 − 4 = 20.
  static const double mainCardCornerRadius = 20;

  /// Dark preset window veil — a clear black mask. High enough that chat
  /// text stays readable, low enough that the desktop still shows through
  /// faintly. Must stay below 255: an opaque fill hides the wallpaper.
  static const int chromeTintDarkAlpha = 225;

  /// Light preset window veil — a clear white mask with the same see-through
  /// job as [chromeTintDarkAlpha]. Not a frosted material.
  static const int lightSurfaceGlassAlpha = 217;

  /// Clear (non-blurred) window veil shared by shell regions. Dark paints
  /// black; light paints white. Wallpaper shows through sharply — do not
  /// restore NSVisualEffectView or BackdropFilter on this layer.
  static Color surfaceGlassTint({required bool isDark}) => Color.fromARGB(
    isDark ? chromeTintDarkAlpha : lightSurfaceGlassAlpha,
    isDark ? 0 : 255,
    isDark ? 0 : 255,
    isDark ? 0 : 255,
  );

  /// Translucent overlay on shell glass — same alpha in both presets; overlay
  /// color flips with mode (light wash in dark, dark wash in light).
  static Color chromeGlassOverlay({required bool isDark, required int alpha}) =>
      Color.fromARGB(
        alpha,
        isDark ? 255 : 0,
        isDark ? 255 : 0,
        isDark ? 255 : 0,
      );

  /// Search capsule and similar chrome control fills on glass.
  static const int chromeControlFillAlpha = 12;

  static Color chromeControlFill({required bool isDark}) =>
      chromeGlassOverlay(isDark: isDark, alpha: chromeControlFillAlpha);

  /// Shared light-on-glass foreground for shell chrome — identical in both
  /// presets. Widgets must resolve icon, label, and search chrome through
  /// the helpers below; do not branch on theme or hardcode divergent colors.
  static const Color chromeForegroundColor = Colors.white;

  /// Resting chrome icon alpha on glass (both presets).
  static const int chromeIconMutedAlpha = 255;

  /// Search field border alpha on glass (both presets).
  static const int chromeSearchBorderAlpha = 110;

  /// Search field placeholder alpha on glass (both presets).
  static const int chromeSearchPlaceholderAlpha = 190;

  /// Primary foreground on shell chrome (icons, selected tab labels).
  static Color chromeForeground() => chromeForegroundColor;

  /// Resting icon on shell chrome.
  static Color chromeIconMuted() =>
      chromeForegroundColor.withAlpha(chromeIconMutedAlpha);

  /// Search field border on shell chrome.
  static Color chromeSearchBorder() =>
      chromeForegroundColor.withAlpha(chromeSearchBorderAlpha);

  /// Search field icon on shell chrome.
  static Color chromeSearchIcon() => chromeIconMuted();

  /// Search field placeholder text on shell chrome.
  static Color chromeSearchPlaceholder() =>
      chromeForegroundColor.withAlpha(chromeSearchPlaceholderAlpha);

  /// Content height of one sidebar bottom-nav button: compact vertical
  /// padding ×2 (16) + icon (20) + icon–label gap (4) + label line
  /// (10 × 1.1 = 11) = 51.
  static const double sidebarBottomNavButtonExtent = 51;

  /// Horizontal margin on each sidebar bottom-nav button. At the default
  /// sidebar width the row slot is (224 − 4 card inset − 16 nav padding) / 3
  /// = 68; margin 8.5 makes the visible button exactly
  /// [sidebarBottomNavButtonExtent] wide — a perfect square by default.
  /// Wider sidebars stretch the buttons wider than square.
  static const double sidebarBottomNavButtonMargin =
      ((conversationListExtent -
                  conversationListCardInset -
                  LicoContentSpacing.compact * 2) /
              3 -
          sidebarBottomNavButtonExtent) /
      2;

  static const double searchFieldHeight = 32;

  /// Vertical rhythm between stacked primary sidebar controls and the next
  /// semantic row. Search → action and action → group label use one gap.
  static const double sidebarPrimaryControlGap = 14;

  /// Height of the sidebar top row that hosts the native macOS traffic-light
  /// cluster. The row replaces the old sidebar heading text; the lights
  /// overlay it vertically centered with an equal left inset.
  static const double trafficLightRowExtent = 40;

  /// Reserved width of the traffic-light anchor at a sidebar card top-left;
  /// the native cluster (three buttons plus equal edge insets) overlays this
  /// zone, so list content must not start left of it.
  static const double trafficLightAnchorExtent = 88;

  static const double windowCornerRadius = 24;

  static const double hairline = 0.5;
}
