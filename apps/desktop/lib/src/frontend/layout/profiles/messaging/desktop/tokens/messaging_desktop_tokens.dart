import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/layout/layout_visual_tokens.dart';

/// Geometry for the Messaging desktop presentation: a window-chrome top band
/// above a transparent shell on native frosted glass, a rounded main content
/// card, and (in Agents) a floating conversation-list card on a shared chat
/// canvas.
final LayoutVisualTokens messagingDesktopTokens = LayoutVisualTokens(
  spacingUnit: 6,
  density: 0.92,
  cardRadius: 10,
  elevation: 0,
  navigationExtent: 68,
  contentMaxWidth: 1600,
  typographyScale: 0.95,
  motionDuration: const Duration(milliseconds: 150),
);

/// Profile-private measurements shared by the Messaging desktop shell.
abstract final class MessagingDesktopMetrics {
  /// Far-left destination column on the unified frosted-glass shell.
  static const double navigationRailExtent = 56;

  /// Reference width of the conversation-list column; the workspace keeps
  /// the user-draggable width, clamped by its own bounds.
  static const double conversationListExtent = 280;

  /// Inset of the floating conversation-list glass card on the shared chat
  /// canvas (tighter than [mainCardMargin] so the list sits closer to the
  /// main content card edges).
  static const double conversationListCardInset = 4;

  /// Inner radius of the floating conversation-list glass card. The outer
  /// content radius remains inner radius + card inset: 16 = 12 + 4.
  static const double conversationListCardCornerRadius = 12;

  /// Translucent card fill on the dark chat canvas — same alpha family as the
  /// Dashboard folder sidebar card on native glass.
  static const int conversationListCardTintDarkAlpha = 22;

  /// Translucent card fill on the light chat canvas.
  static const int conversationListCardTintLightAlpha = 140;

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

  /// Empty bands between the group roster and the floating header/composer.
  static const double groupRosterHeaderGap = 10;
  static const double groupRosterComposerGap = 10;

  /// Detached member capsule in the right transcript band. Its width matches
  /// the group header capsule button (38 px avatar + 8 px vertical padding on
  /// each side), so the two controls share one vertical axis and silhouette.
  static const double groupRosterExtent = 54;
  static const double groupRosterContentInset = 2;
  static const double groupRosterScrollbarThickness = 2;
  static const double groupRosterMinimumVisibleExtent = 128;
  static const int groupRosterVisibleMemberCount = 5;
  static const double groupRosterMemberExtent = 54;
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

  /// Corner radius of the conversation-header capsule (stadium / pill).
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
  /// insetV×2 + padV×2 + avatar(30).
  static const double conversationHeaderOverlayExtent =
      conversationHeaderCapsuleInsetV * 2 +
      conversationHeaderCapsulePadV * 2 +
      30;

  /// Horizontal inset of the floating composer capsule.
  static const double conversationComposerCapsuleInsetH = 12;

  /// Vertical inset of the floating composer capsule from the bottom edge.
  static const double conversationComposerCapsuleInsetV = 10;

  /// Corner radius of the floating composer capsule (matches header capsule).
  static const double conversationComposerCapsuleCornerRadius =
      conversationHeaderCapsuleCornerRadius;

  /// Shared BackdropFilter sigma for conversation overlay glass (header
  /// capsules + floating composer). One value — keep header and input matched.
  static const double conversationOverlayGlassBlurSigma = 20;

  /// Approximate height reserved under the floating composer so the
  /// transcript clears it (padding + field + send row).
  static const double conversationComposerOverlayExtent = 78;

  /// Extra transcript clearance when context capsules (workspace, model, …)
  /// sit above the floating composer.
  static const double conversationComposerCapsuleRowExtent = 40;

  /// Deprecated alias — use [conversationComposerCapsuleRowExtent].
  static const double conversationComposerWorkspaceChipExtent =
      conversationComposerCapsuleRowExtent;

  /// Primary column width for the composer runtime selector. Wide enough to
  /// keep the longest control name (Reasoning Effort) on one line beside its
  /// current value.
  static const double composerRuntimeSelectorPrimaryWidth = 224;

  /// Submenu column width for model / effort option lists. Primary + gap +
  /// submenu stays inside the hover popover's own maximum width.
  static const double composerRuntimeSelectorSubmenuWidth = 188;

  /// Max height of the runtime selector hover popover (primary ± submenu).
  static const double composerRuntimeSelectorPopoverMaxHeight = 260;

  /// Max height of composer-adjacent option menus.
  static const double composerOptionPopoverMaxHeight = 360;

  /// Max height of the bounded, scrollable runtime selector submenu.
  static const double composerRuntimeSelectorSubmenuMaxHeight = 220;

  /// Gap between the fixed primary runtime card and the detached submenu card.
  static const double composerRuntimeSelectorSubmenuGap = 8;

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

  /// Neutral hairline alpha on user bubbles (dark canvas) — uses theme
  /// [line], never brand/primary (brand rims read as olive 泛黄).
  static const int userBubbleGlassBorderAlphaDark = 90;

  /// Neutral hairline alpha on user bubbles (light canvas).
  static const int userBubbleGlassBorderAlphaLight = 100;

  /// Neutral transparent fill for user message bubbles.
  static Color userBubbleGlassFill({required bool isDark}) =>
      Colors.transparent.withAlpha(
        isDark ? userBubbleGlassFillDarkAlpha : userBubbleGlassFillLightAlpha,
      );

  /// Neutral rim for frosted user bubbles on [line].
  static Color userBubbleGlassBorder(Color line, {required bool isDark}) =>
      line.withAlpha(
        isDark
            ? userBubbleGlassBorderAlphaDark
            : userBubbleGlassBorderAlphaLight,
      );

  /// Black readability veil on floating conversation overlays (dark).
  /// Layered with [conversationOverlayGlassFill] and blur so menus and
  /// popovers remain distinct from live content without becoming opaque.
  static const int conversationOverlayReadabilityVeilDarkAlpha = 84;

  /// Lighter counterpart for floating overlays on the light preset.
  static const int conversationOverlayReadabilityVeilLightAlpha = 40;

  /// Shared black readability veil for floating conversation overlays — use
  /// with overlay glass, not as a standalone opaque panel.
  static Color conversationOverlayReadabilityVeilFill({required bool isDark}) =>
      Colors.black.withAlpha(
        isDark
            ? conversationOverlayReadabilityVeilDarkAlpha
            : conversationOverlayReadabilityVeilLightAlpha,
      );

  /// Fill wash for the floating conversation-list card. Widgets must use this
  /// helper (or the named alphas above) — do not hardcode tint alphas in
  /// presentation code.
  static Color conversationListCardFill({required bool isDark}) =>
      Colors.white.withAlpha(
        isDark
            ? conversationListCardTintDarkAlpha
            : conversationListCardTintLightAlpha,
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
          color: Colors.black.withAlpha(
            isDark
                ? conversationListCardShadowAlphaDark
                : conversationListCardShadowAlphaLight,
          ),
          blurRadius: conversationListCardShadowBlur,
          offset: const Offset(0, conversationListCardShadowOffsetY),
        ),
      ];

  /// Window inset of the unified content card on its right and bottom
  /// edges; the card's top edge meets the chrome band and its left edge sits
  /// flush against the destination rail.
  static const double mainCardMargin = 8;

  /// Outer corner radius of the unified content card.
  static const double mainCardCornerRadius = 16;

  /// Black veil on the main conversation content card (dark). The card itself
  /// is transparent glass over native VE; without this mask, dense chat/list
  /// text loses contrast. Same character as the retired shell chrome black
  /// tint (historically `chromeTintDarkAlpha` 77). Shell band/rail stay
  /// untinted — only this reading surface uses the veil.
  static const int mainContentCardOverlayDarkAlpha = 77;

  /// Black veil on the main conversation content card (light). Same
  /// readability role as the dark overlay; lighter alpha so the card does not
  /// read as a solid slab on bright VE.
  static const int mainContentCardOverlayLightAlpha = 40;

  /// The unified card has no painted rim. Native glass, fill, and elevation
  /// establish its boundary without leaving a seam beside edge-grown rails.
  static const int mainContentCardBorderAlphaDark = 0;

  /// Light-preset counterpart of [mainContentCardBorderAlphaDark].
  static const int mainContentCardBorderAlphaLight = 0;

  /// Drop-shadow alpha on the main content card (dark).
  static const int mainContentCardShadowAlphaDark =
      conversationListCardShadowAlphaDark;

  /// Drop-shadow alpha on the main content card (light).
  static const int mainContentCardShadowAlphaLight =
      conversationListCardShadowAlphaLight;

  /// Drop-shadow blur of the main content card.
  static const double mainContentCardShadowBlur =
      conversationListCardShadowBlur;

  /// Drop-shadow Y offset of the main content card.
  static const double mainContentCardShadowOffsetY =
      conversationListCardShadowOffsetY;

  /// Black mask fill for the main conversation content card (over native VE).
  /// Shell code must use this helper — do not hardcode overlay alphas.
  static Color mainContentCardFill({required bool isDark}) =>
      Colors.black.withAlpha(
        isDark
            ? mainContentCardOverlayDarkAlpha
            : mainContentCardOverlayLightAlpha,
      );

  /// Border color for the main conversation content card on [line].
  static Color mainContentCardBorder(Color line, {required bool isDark}) =>
      line.withAlpha(
        isDark
            ? mainContentCardBorderAlphaDark
            : mainContentCardBorderAlphaLight,
      );

  /// Elevation shadow for the main conversation content card.
  static List<BoxShadow> mainContentCardShadows({required bool isDark}) => [
    BoxShadow(
      color: Colors.black.withAlpha(
        isDark
            ? mainContentCardShadowAlphaDark
            : mainContentCardShadowAlphaLight,
      ),
      blurRadius: mainContentCardShadowBlur,
      offset: const Offset(0, mainContentCardShadowOffsetY),
    ),
  ];

  /// Full-width window-chrome band height; the system traffic lights stay
  /// vertically centered inside its left inset, mirroring the other
  /// profiles' top-band convention.
  static const double topBandExtent = 48;

  /// Historical reference only. Shell blur comes from the native
  /// NSVisualEffectView; Flutter chrome applies tint via [surfaceGlassTint]
  /// and does not use BackdropFilter.
  static const double chromeGlassBlurSigma = 28;

  /// Dark preset shell tint alpha — 0 (native NSVisualEffectView only).
  /// Flutter color overlays (especially white, and black in dark mode) severely
  /// degrade frosted-glass material quality; both presets rely on native VE.
  static const int chromeTintDarkAlpha = 0;

  /// Light preset shell tint alpha — 0 (native NSVisualEffectView only).
  /// Kept as a named token so tests and docs reference one shared path.
  static const int lightSurfaceGlassAlpha = 0;

  /// Frosted-glass tint shared by chrome band, destination rail, and the
  /// content region beneath the unified main card. Both presets return fully
  /// transparent — native NSVisualEffectView provides the frosted material.
  static Color surfaceGlassTint({required bool isDark}) => Colors.transparent;

  /// Translucent overlay on shell glass — same alpha in both presets; overlay
  /// color flips with mode (light wash in dark, dark wash in light).
  static Color chromeGlassOverlay({required bool isDark, required int alpha}) =>
      isDark ? Colors.white.withAlpha(alpha) : Colors.black.withAlpha(alpha);

  /// Search capsule and similar chrome control fills on glass.
  static const int chromeControlFillAlpha = 12;

  /// Icon-button and tab hover wash on glass.
  static const int chromeControlHoverAlpha = 10;

  /// Selected conversation tab fill on glass.
  static const int chromeTabSelectedAlpha = 26;

  static Color chromeControlFill({required bool isDark}) =>
      chromeGlassOverlay(isDark: isDark, alpha: chromeControlFillAlpha);

  static Color chromeControlHover({required bool isDark}) =>
      chromeGlassOverlay(isDark: isDark, alpha: chromeControlHoverAlpha);

  static Color chromeTabSelectedFill({required bool isDark}) =>
      chromeGlassOverlay(isDark: isDark, alpha: chromeTabSelectedAlpha);

  /// Shared light-on-glass foreground for shell chrome — identical in both
  /// presets. Widgets must resolve icon, label, and search chrome through
  /// the helpers below; do not branch on theme or hardcode divergent colors.
  static const Color chromeForegroundColor = Colors.white;

  /// Resting chrome icon alpha on glass (both presets).
  static const int chromeIconMutedAlpha = 255;

  /// Disabled chrome icon alpha on glass (both presets).
  static const int chromeIconDisabledAlpha = 120;

  /// Search field border alpha on glass (both presets).
  static const int chromeSearchBorderAlpha = 110;

  /// Search field placeholder alpha on glass (both presets).
  static const int chromeSearchPlaceholderAlpha = 190;

  /// Primary foreground on shell chrome (icons, selected tab labels).
  static Color chromeForeground() => chromeForegroundColor;

  /// Resting icon on shell chrome.
  static Color chromeIconMuted() =>
      chromeForegroundColor.withAlpha(chromeIconMutedAlpha);

  /// Hovered icon on shell chrome.
  static Color chromeIconHover() => chromeForegroundColor;

  /// Disabled icon on shell chrome.
  static Color chromeIconDisabled() =>
      chromeForegroundColor.withAlpha(chromeIconDisabledAlpha);

  /// Search field border on shell chrome.
  static Color chromeSearchBorder() =>
      chromeForegroundColor.withAlpha(chromeSearchBorderAlpha);

  /// Search field icon on shell chrome.
  static Color chromeSearchIcon() => chromeIconMuted();

  /// Search field placeholder text on shell chrome.
  static Color chromeSearchPlaceholder() =>
      chromeForegroundColor.withAlpha(chromeSearchPlaceholderAlpha);

  static const double searchFieldHeight = 32;
  static const double searchFieldCornerRadius = mainCardCornerRadius;

  /// Vertical rhythm between stacked primary sidebar controls and the next
  /// semantic row. Search → action and action → group label use one gap.
  static const double sidebarPrimaryControlGap = 14;

  /// Left inset of the chrome band so its content clears the macOS
  /// traffic-light cluster (same reservation as the Dashboard top bar).
  static const double trafficLightInset = 96;

  /// Fixed width of the chrome-band search field; below
  /// [chromeSearchCollapseWidth] the band degrades it to an icon button.
  static const double chromeSearchFieldWidth = 200;
  static const double chromeSearchCollapseWidth = 640;

  /// Square extent of the chrome-band right-cluster action buttons.
  static const double chromeActionButtonExtent = 32;

  static const double windowCornerRadius = 24;

  /// Square extent of the rounded-rectangle rail buttons.
  static const double railToggleExtent = 40;

  /// Corner radius of the rounded-rectangle rail buttons.
  static const double railToggleRadius = 12;

  static const double hairline = 0.5;
}
