import 'dart:ui' show Color;

import 'package:licoup/src/frontend/layout/layout_visual_tokens.dart';

export 'package:licoup/src/frontend/shared/ui/messaging_desktop_tokens.dart'
    show MessagingDesktopMetrics;

/// Geometry for the Desktop presentation: one spacious main canvas with a
/// floating stretchable capsule dock below, floating feature cards one
/// Z-level above the canvas, and a Launchpad-style glass app store.
final LayoutVisualTokens desktopDesktopTokens = LayoutVisualTokens(
  spacingUnit: 6,
  density: 0.92,
  cardRadius: 14,
  elevation: 0,
  navigationExtent: 68,
  contentMaxWidth: 1600,
  typographyScale: 0.95,
  motionDuration: const Duration(milliseconds: 150),
);

/// Desktop-owned metrics for the dock bar, floating cards, the Launchpad
/// panel, and the settings copy. Independent from the shared messaging
/// metrics so the surfaces can diverge.
abstract final class DesktopDesktopMetrics {
  /// Dock bar (rounded rectangle, pure black surface).
  static const double dockBarHeight = 64;
  static const double dockBarRadius = 18;
  static const double dockBarBottomInset = 14;
  static const double dockBarSideInset = 24;
  static const double dockBarMaxWidth = 1120;
  static const double dockBarMinWidth = 520;
  static const double dockIconExtent = 44;
  static const double dockIconRadius = 13;
  static const double dockIconGlyphSize = 22;
  static const double dockIconGap = 8;
  static const double dockActiveDotDiameter = 4;
  static const double dockDropZoneExtent = 14;
  static const double dockInputWidth = 300;
  static const double dockInputHeight = 44;
  static const double dockInputRadius = 12;
  static const double dockConversationButtonExtent = 36;

  /// Width the bar reserves on its right for the floating input row
  /// (对话 button + gap + input + trailing padding).
  static const double dockInputSlotExtent =
      dockConversationButtonExtent + dockIconGap + dockInputWidth + 20;

  /// The region the dock bar can cover at the bottom of the main area.
  static const double mainAreaBottomInset =
      dockBarHeight + dockBarBottomInset + 8;

  /// Floating feature cards.
  static const double floatingCardRadius = 16;
  static const double floatingCardHeaderExtent = 44;
  static const double floatingCardWidth = 760;
  static const double floatingCardHeight = 540;
  static const double floatingCardCascadeStep = 34;

  /// Launchpad app store.
  static const double launchpadRadius = 24;
  static const double launchpadIconExtent = 60;
  static const double launchpadIconRadius = 15;
  static const double launchpadColumnGap = 28;
  static const double launchpadRowGap = 26;
  static const double launchpadMaxWidth = 760;

  /// Desktop settings copy.
  static const double settingsNavCardWidth = 232;
  static const double settingsNavCardRadius = 14;
  static const double settingsTrafficLightRowExtent = 28;

  /// Traffic-light anchor band height reported to the window chrome.
  static const double trafficLightAnchorExtent = 28;
}

/// The uniform pure-black surface color for Desktop chrome (dock bar,
/// Launchpad panel, floating cards, settings copy cards) — no frosted gray.
const Color desktopDesktopSurfaceBlack = Color(0xFF000000);

/// Foreground roles on the black Desktop surfaces.
abstract final class DesktopDesktopOnBlack {
  static const Color text = Color(0xFFFFFFFF);
  static const Color textSecondary = Color(0xB4FFFFFF);
  static const Color textMuted = Color(0x80FFFFFF);
  static const Color line = Color(0x24FFFFFF);
  static const Color hoverOverlay = Color(0x12FFFFFF);
  static const Color fill = Color(0x0AFFFFFF);
}
