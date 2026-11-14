import 'package:flutter/material.dart';

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

  /// Golden-ratio default split: the conversation detail column takes this
  /// share of the whole window width, so the list column keeps the minor
  /// 0.382 share minus whatever leading chrome (the navigation rail) owns.
  static const double conversationDetailGoldenShare = 0.618;

  /// Ceiling on the golden-ratio list default so the column stays narrow —
  /// a dragged width may still reach [conversationListMaxExtent].
  static const double conversationListGoldenCapExtent = 260;

  /// Drag-handle hit target on the shared sidebar column.
  static const double conversationListDividerWidth = 8;

  /// Minimum remaining width for the detail pane when the column grows.
  static const double conversationDetailMinExtent = 360;

  /// Inset of the floating conversation-list glass card within the main
  /// content region — the card floats 4 inside the region (6 from the window
  /// edge), keeping a visible glass gutter around the one floating card.
  static const double conversationListCardInset = 10;

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
  static const double conversationHeaderCapsulePadH = 20;

  /// Inner vertical padding inside the header capsule.
  static const double conversationHeaderCapsulePadV = 8;

  /// Diameter of the single conversation overflow control.
  static const double conversationHeaderMenuExtent = 44;

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

  /// Fixed corner radius of the two-row floating composer.
  static const double conversationComposerCapsuleCornerRadius =
      conversationHeaderCapsuleCornerRadius;

  /// Shared BackdropFilter sigma for conversation overlay glass (header
  /// capsules + floating composer). One value — keep header and input matched.
  /// Kept low so the glass reads clear （清透） rather than frosted.
  static const double conversationOverlayGlassBlurSigma = 12;

  /// Initial clearance until the floating composer reports its laid-out height.
  static const double conversationComposerOverlayExtent = 144;

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

  /// Accent edge-light shared by conversation bubbles: a thin, bright rim
  /// line and nothing else — no light field, no fog. Interiors stay dark
  /// glass. Never brand/primary — lemon rims read as olive 泛黄 on the dark
  /// chat canvas.
  static const double bubbleEdgeRimWidth = 1;

  /// Rim line alpha at the top edge (dark canvas) — thin and bright.
  static const int bubbleEdgeGlowAlphaDark = 245;

  /// Rim line alpha at the top edge (light canvas).
  static const int bubbleEdgeGlowAlphaLight = 210;

  /// Rim line alpha at the bottom edge (dark canvas).
  static const int bubbleEdgeGlowDimAlphaDark = 120;

  /// Rim line alpha at the bottom edge (light canvas).
  static const int bubbleEdgeGlowDimAlphaLight = 105;

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

  /// Agent bubble interior: the shared black readability veil, not an accent
  /// tint — the accent lives only on the rim light.
  /// Resting (unlit) neutral hairline on conversation bubbles — the plain
  /// style the hover-lit edge light fades back to.
  static Color bubbleRestingBorder(Color line, {required bool isDark}) =>
      line.withAlpha(isDark ? 90 : 100);

  /// Bubble corner radius away from the author anchor.
  static const double bubbleCornerRadius = 16;

  /// Tighter corner at the author anchor: top-left for agent bubbles (toward
  /// the avatar), bottom-right for the user's own (toward the screen edge).
  static const double bubbleAnchorCornerRadius = 6;

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
  static Color conversationListCardFill({required bool isDark}) => isDark
      // Black mask over the galaxy — slightly translucent, never a
      // white/gray wash.
      ? const Color(0xB807070A)
      : const Color.fromARGB(conversationListCardTintLightAlpha, 255, 255, 255);

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

  /// Directional rim for control-layer glass. Painted as a broad light ramp in
  /// [chromeForegroundColor], never brand/primary. Lit and far-edge alphas
  /// differ so the silhouette reads as a catch of light, not a drawn outline.
  static const double glassEdgeRimWidth = 0.75;

  /// Lit-side specular alpha on a dark canvas (≈ 0.16).
  static const int glassEdgeRimHiAlphaDark = 42;

  /// Lit-side specular alpha on a light canvas (≈ 0.38).
  static const int glassEdgeRimHiAlphaLight = 98;

  /// Shadow-side specular alpha on a dark canvas (≈ 0.03).
  static const int glassEdgeRimLoAlphaDark = 8;

  /// Shadow-side specular alpha on a light canvas (≈ 0.08).
  static const int glassEdgeRimLoAlphaLight = 20;

  /// Bright catch of light on the lit side of the silhouette.
  static Color glassEdgeRimHi({required bool isDark}) => chromeForegroundColor
      .withAlpha(isDark ? glassEdgeRimHiAlphaDark : glassEdgeRimHiAlphaLight);

  /// Soft edge definition on the side facing away from the light.
  static Color glassEdgeRimLo({required bool isDark}) => chromeForegroundColor
      .withAlpha(isDark ? glassEdgeRimLoAlphaDark : glassEdgeRimLoAlphaLight);

  /// Window inset of the unified content region on every edge. Narrow (4) by
  /// Page inset inside the unified main content region. Every single-pane

  /// Page inset inside the unified main content region. Every single-pane
  /// destination (Settings, Models, Skill Hub, Plugins, Monitoring, Mobile
  /// Relay) uses this same padding so content does not hug the region chrome.
  static const EdgeInsets mainPanePadding = EdgeInsets.fromLTRB(24, 20, 24, 40);

  /// Outer corner radius of the unified content region's clip — concentric
  /// with the window: [windowCornerRadius] − [mainCardMargin] = 24 − 4 = 20.
  static const double mainCardCornerRadius = 20;

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

  static const double searchFieldHeight = 32;

  /// Vertical rhythm between stacked primary sidebar controls and the next
  /// semantic row. Search → action and action → group label use one gap.
  static const double sidebarPrimaryControlGap = 14;

  /// Height of the sidebar top row that hosts the native macOS traffic-light
  /// cluster. The row replaces the old sidebar heading text; the lights
  /// overlay it vertically centered with an equal left inset.
  static const double trafficLightRowExtent = 40;

  /// Height of the sidebar's first row on flat shells (the Dashboard plain
  /// sidebar): vertically centred on the native traffic-light cluster, it
  /// hosts the search capsule and the column's actions.
  static const double sidebarTopRowExtent = 52;

  /// Outer geometry of one sidebar list row, shared by the conversation
  /// list and the index rows (Features, Settings) so every sidebar list
  /// reads with the same metrics.
  static const double sidebarRowExtent = 64;

  /// Height of one single-line index row (Features, Settings): shorter
  /// than the two-line conversation row but sharing its horizontal inset,
  /// radius and fills, so icons sit on the avatar column's axis.
  static const double sidebarIndexRowExtent = 44;
  static const double sidebarRowGap = 2;
  static const double sidebarRowHorizontalInset = 10;
  static const double sidebarRowLeadingExtent = 44;
  static const double sidebarRowIconExtent = 20;
  static const double sidebarRowLabelGap = 10;

  /// Alpha (0-255) of the flat sidebar row's hover wash.
  static const int sidebarRowHoverAlpha = 8;

  /// Width of the pinned avatar column at a hosted sidebar's left edge.
  static const double avatarColumnExtent = 56;

  /// Row height of one avatar in that column.
  static const double avatarColumnTileExtent = 52;

  /// Reserved width of the traffic-light anchor at a sidebar card top-left;
  /// the native cluster (three buttons plus equal edge insets) overlays this
  /// zone, so list content must not start left of it.
  static const double trafficLightAnchorExtent = 88;

  static const double windowCornerRadius = 24;

  static const double hairline = 1;
}
