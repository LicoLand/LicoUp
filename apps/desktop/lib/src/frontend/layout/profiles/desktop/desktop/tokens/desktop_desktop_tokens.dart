import 'dart:ui' show Color, Offset;

import 'package:flutter/painting.dart' show BoxShadow;

import 'package:licoup/src/frontend/layout/layout_visual_tokens.dart';

/// Geometry for the Desktop presentation: a two-pane workspace — left content
/// (features grid, settings, or one app) beside the permanent conversation —
/// over a full-width bottom bar split into the navigation icon strip and the
/// conversation composer. Desktop owns every value below; no token is shared
/// with another profile, so Desktop chrome can diverge without side effects.
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

/// Desktop-owned glass recipe. The values deliberately replicate the
/// Dashboard glass family (clear veil, translucent card fills, hairline rims,
/// soft elevation) as a private copy: the two profiles share no token source
/// and evolve independently.
abstract final class DesktopDesktopGlass {
  /// Opaque window ground behind every Desktop surface; no blur on this layer.
  static Color veil({required bool isDark}) =>
      isDark ? const Color(0xFF000000) : const Color(0xFFF4E3DC);

  /// Translucent card fill over the veil — thin enough that the ground reads
  /// through instead of stacking into a gray haze.
  static Color cardFill({required bool isDark}) =>
      Color.fromARGB(isDark ? 12 : 92, 255, 255, 255);

  /// Hairline rim on a floating card, resolved from the palette line color.
  static Color cardBorder(Color line, {required bool isDark}) =>
      line.withAlpha(isDark ? 90 : 120);

  /// Soft elevation under a floating card.
  static List<BoxShadow> cardShadows({required bool isDark}) => [
    BoxShadow(
      color: Color.fromARGB(isDark ? 60 : 20, 0, 0, 0),
      blurRadius: 16,
      offset: const Offset(0, 4),
    ),
  ];

  /// Hover wash on glass controls — overlay color flips with the mode.
  static Color hoverFill({required bool isDark}) =>
      Color.fromARGB(18, isDark ? 255 : 0, isDark ? 255 : 0, isDark ? 255 : 0);

  /// Quiet resting fill for chrome controls on glass.
  static Color controlFill({required bool isDark}) =>
      Color.fromARGB(12, isDark ? 255 : 0, isDark ? 255 : 0, isDark ? 255 : 0);
}

/// Desktop-owned geometry for the split workspace, the bottom bar, and the
/// top chrome row.
abstract final class DesktopDesktopMetrics {
  /// Uniform gutter between the window edge and the split workspace.
  static const double windowInset = 12;

  /// Gap between the two panes and between the panes and the bottom bar.
  static const double regionGap = 10;

  /// Top chrome band hosting the traffic-light anchor and the collapse
  /// toggle; pane content starts below it.
  static const double chromeRowExtent = 40;

  /// Collapse/expand toggle size, immediately right of the traffic lights.
  static const double collapseToggleExtent = 32;

  /// Width the conversation list reserves for the shell chrome row (traffic
  /// lights + collapse toggle) when the shell owns the anchors: leading inset
  /// + anchor + gap + toggle.
  static const double chromeLeadingExtent = 8 + 96 + 8 + collapseToggleExtent;

  /// Bottom bar (two rounded boxes: the icon strip and the composer).
  static const double dockBarHeight = 64;
  static const double dockBarRadius = 18;
  static const double dockIconExtent = 44;
  static const double dockIconRadius = 13;
  static const double dockIconGlyphSize = 22;
  static const double dockIconGap = 8;
  static const double dockActiveDotDiameter = 4;
  static const double dockDropZoneExtent = 14;
  static const double dockBoxPaddingH = 10;

  /// Width of one icon slot (tile + gap) — the snap unit of the collapsed
  /// conversation list and its aligned icon strip.
  static const double dockIconSlot = dockIconExtent + dockIconGap;

  /// Horizontal extent of a collapsed-list snap of [slots] icons, including
  /// the strip's inner padding.
  static double dockIconSlotsExtent(int slots) =>
      dockBoxPaddingH * 2 + slots * dockIconExtent + (slots - 1) * dockIconGap;

  /// Minimum icon slots in the collapsed strip: 设置, 功能, and the most
  /// recently used app always fit, with room for one more. Four slots also
  /// keep the conversation list above its own minimum extent (196).
  static const int dockMinIconSlots = 4;

  /// Left pane bounds while it is open.
  static const double leftPaneMinExtent = 360;
  static const double leftPaneDefaultExtent = 560;

  /// Minimum width the conversation keeps beside an open left pane.
  static const double conversationMinExtent = 420;

  /// Corner radius of the two pane cards.
  static const double paneRadius = 20;

  /// Extra height the composer box gains while the left pane is collapsed
  /// (the expanded input carries the Assistant and Adaptive Flywheel
  /// capsules above the field).
  static const double composerExpandedExtraExtent = 96;

  /// Drag-handle hit width on the pane split; the handle paints nothing.
  static const double splitHandleExtent = regionGap;

  /// Features grid (the left-pane app store).
  static const double featuresIconExtent = 56;
  static const double featuresIconRadius = 15;
  static const double featuresColumnGap = 12;
  static const double featuresRowGap = 18;

  /// Default width of the settings section index rail inside the left pane;
  /// the shared panel's own minimum (120) wraps section labels at Desktop
  /// pane widths. Persisted through the Desktop-owned settingsIndex channel;
  /// user drags always win.
  static const double settingsIndexDefaultExtent = 168;

  /// Traffic-light anchor band height reported to the window chrome.
  static const double trafficLightAnchorExtent = 28;
}
