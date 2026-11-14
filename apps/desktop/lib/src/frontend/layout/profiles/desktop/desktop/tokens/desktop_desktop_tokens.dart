import 'dart:ui' show Color, Offset;

import 'package:flutter/painting.dart' show BoxShadow;

import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/layout/layout_visual_tokens.dart';

/// Geometry for the Desktop presentation: a work area hosting one app at a
/// time beside the permanent chat sidebar, with a floating dock at the bottom
/// of the work area. Desktop owns every value below; no token is shared with
/// another profile, so Desktop chrome can diverge without side effects.
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

/// Desktop-owned glass recipe for the pieces only Desktop paints: the window
/// veil, the floating dock, and chrome-control washes. The window pane cards
/// share the [LicoPaneGlass] recipe instead.
abstract final class DesktopDesktopGlass {
  /// Opaque window ground behind every Desktop surface; no blur on this layer.
  static Color veil(LayoutPalette colors) => colors.surfaceSunken;

  /// Hover wash on glass controls — overlay color flips with the mode.
  static Color hoverFill({required bool isDark}) =>
      Color.fromARGB(18, isDark ? 255 : 0, isDark ? 255 : 0, isDark ? 255 : 0);

  /// Quiet resting fill for chrome controls on glass.
  static Color controlFill({required bool isDark}) =>
      Color.fromARGB(12, isDark ? 255 : 0, isDark ? 255 : 0, isDark ? 255 : 0);

  /// The floating dock: denser than a pane card so it reads above the work
  /// area content it floats over.
  static Color dockFill(LayoutPalette colors) =>
      colors.isDark ? const Color(0xB8101015) : const Color(0xC7FFFFFF);

  /// The dock's specular rim.
  static const Color dockRimHi = Color(0x24FFFFFF);
  static const Color dockRimLo = Color(0x0AFFFFFF);
  static const Color dockRimHiLight = Color(0x14000000);
  static const Color dockRimLoLight = Color(0x0A000000);

  static List<BoxShadow> dockShadows({required bool isDark}) => [
    BoxShadow(
      color: Color.fromARGB(isDark ? 128 : 34, 0, 0, 0),
      blurRadius: isDark ? 24 : 28,
      offset: isDark ? const Offset(0, 8) : const Offset(0, 10),
    ),
    BoxShadow(
      color: Color.fromARGB(isDark ? 77 : 14, 0, 0, 0),
      blurRadius: isDark ? 2 : 4,
      offset: const Offset(0, 1),
    ),
  ];

  /// Dock slot tiles.
  static Color dockTileHoverFill({required bool isDark}) => Color.fromARGB(
    isDark ? 20 : 13,
    isDark ? 255 : 0,
    isDark ? 255 : 0,
    isDark ? 255 : 0,
  );
  static Color dockTileActiveFill({required bool isDark}) => Color.fromARGB(
    isDark ? 15 : 10,
    isDark ? 255 : 0,
    isDark ? 255 : 0,
    isDark ? 255 : 0,
  );
  static Color dockTileActiveRim({required bool isDark}) => Color.fromARGB(
    isDark ? 26 : 20,
    isDark ? 255 : 0,
    isDark ? 255 : 0,
    isDark ? 255 : 0,
  );

  /// Dock running dots and group dividers.
  static Color dockDotColor({required bool isDark}) => Color.fromARGB(
    isDark ? 115 : 89,
    isDark ? 255 : 0,
    isDark ? 255 : 0,
    isDark ? 255 : 0,
  );
  static Color dockDividerColor({required bool isDark}) => Color.fromARGB(
    isDark ? 26 : 26,
    isDark ? 255 : 0,
    isDark ? 255 : 0,
    isDark ? 255 : 0,
  );

  /// The hover label's fill and rim.
  static Color dockLabelFill({required bool isDark}) =>
      isDark ? const Color(0xF016161B) : const Color(0xF5FFFFFF);
  static Color dockLabelRim({required bool isDark}) => Color.fromARGB(
    isDark ? 26 : 20,
    isDark ? 255 : 0,
    isDark ? 255 : 0,
    isDark ? 255 : 0,
  );
}

/// Desktop-owned geometry: the work-area card on the left, the chat sidebar
/// card on the right, the shared title row, and the floating dock.
abstract final class DesktopDesktopMetrics {
  /// Gutter between the window edge and the two cards.
  static const double windowInset = 10;

  /// Gutter between the work area and the chat sidebar.
  static const double paneGap = 12;

  /// Corner radius of the two pane cards — concentric with the 24 pt native
  /// window corner: windowInset (10) + paneRadius (14).
  static const double paneRadius = 14;

  /// One title row across the window: the work-area title row and the
  /// sidebar header share this height.
  static const double titleRowExtent = 52;

  /// The app tile in the title row.
  static const double titleIconExtent = 28;

  /// Floating dock.
  static const double dockHeight = 64;
  static const double dockRadius = 22;
  static const double dockIconExtent = 44;
  static const double dockIconRadius = 12;
  static const double dockIconGlyphSize = 22;
  static const double dockIconGap = 8;
  static const double dockPaddingH = 10;
  static const double dockBottomInset = 12;
  static const double dockGroupDividerExtent = 28;
  static const double dockActiveDotDiameter = 4;
  static const double dockDropZoneExtent = 14;
  static const double dockBadgeExtent = 16;

  /// Hover magnification by transform; the layout never changes.
  static const double dockHoverScale = 1.35;
  static const double dockNeighborScale = 1.15;

  /// Bottom space the work-area content reserves so the dock never covers
  /// it.
  static const double dockReservedExtent = dockHeight + dockBottomInset * 2;

  /// Chat sidebar width bounds, and its collapsed rail.
  static const double sidebarDefaultExtent = 400;
  static const double sidebarMinExtent = 340;
  static const double sidebarMaxExtent = 560;
  static const double sidebarRailExtent = 64;

  /// Width the work area keeps before the sidebar yields below its default.
  static const double workAreaMinExtent = 420;
}
