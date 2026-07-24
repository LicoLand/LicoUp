import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/layout/profiles/native/desktop/shell/native_desktop_chrome_metrics.dart';

/// Surface recipes for the Native desktop shell's three-layer system.
///
/// The window background, the icon rail, and the top band form the lowest
/// layer; the workspace container card rests one quiet step above it; the
/// destination detail is the lightest, topmost surface — for Agents, a
/// card nested inside the workspace container. Layers are read through
/// tonal steps alone — at most one hairline and one soft shadow. The brand
/// accent is reserved for state, never for chrome.
abstract final class NativeGlass {
  /// Window-level ambient wash: faint light bleeding down from the top edge,
  /// like light caught inside black glass.
  static BoxDecoration windowAmbient(LayoutPalette colors) {
    return BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Colors.white.withAlpha(colors.isDark ? 7 : 0),
          Colors.white.withAlpha(0),
        ],
        stops: const [0.0, 0.3],
      ),
    );
  }

  /// The workspace container card: the second layer, one quiet tonal step
  /// above the window background — lifted in dark, recessed in light. It
  /// wraps both the conversation list and the conversation detail; the
  /// list stays transparent so it reads as the same surface.
  static BoxDecoration workspaceCard(LayoutPalette colors) {
    final dark = colors.isDark;
    return BoxDecoration(
      color: dark ? colors.surface : colors.surfaceLow,
      borderRadius: BorderRadius.circular(
        NativeDesktopChromeMetrics.detailCornerRadius,
      ),
      border: Border.all(
        color: colors.line.withAlpha(dark ? 70 : 110),
        width: NativeDesktopChromeMetrics.hairline,
      ),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withAlpha(dark ? 70 : 24),
          blurRadius: 18,
          offset: const Offset(0, 5),
          spreadRadius: -8,
        ),
      ],
    );
  }

  /// The third layer (destination detail): a true card — the lightest
  /// surface in the shell, rounded on every corner, standing off the
  /// window's trailing and bottom edges, with one hairline rim and one
  /// soft shadow.
  static BoxDecoration detailCard(LayoutPalette colors) {
    final dark = colors.isDark;
    return BoxDecoration(
      color: dark ? colors.surfaceLow : colors.surface,
      borderRadius: BorderRadius.circular(
        NativeDesktopChromeMetrics.detailCornerRadius,
      ),
      border: Border.all(
        color: colors.line.withAlpha(dark ? 80 : 120),
        width: NativeDesktopChromeMetrics.hairline,
      ),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withAlpha(dark ? 70 : 24),
          blurRadius: 18,
          offset: const Offset(0, 5),
          spreadRadius: -8,
        ),
      ],
    );
  }

  /// The conversation detail card nested inside the workspace container:
  /// the same lightest tone as [detailCard], tighter radius, hairline rim,
  /// no shadow — separation by tone and rim alone.
  static BoxDecoration innerDetailCard(LayoutPalette colors) {
    final dark = colors.isDark;
    return BoxDecoration(
      color: dark ? colors.surfaceLow : colors.surface,
      borderRadius: BorderRadius.circular(
        NativeDesktopChromeMetrics.innerDetailCornerRadius,
      ),
      border: Border.all(
        color: colors.line.withAlpha(dark ? 90 : 130),
        width: NativeDesktopChromeMetrics.hairline,
      ),
    );
  }

  /// Clip for the third layer so content never paints over its rounded
  /// corners.
  static BorderRadius get detailCardClipRadius =>
      BorderRadius.circular(NativeDesktopChromeMetrics.detailCornerRadius);

  /// Clip for the nested conversation detail card.
  static BorderRadius get innerDetailCardClipRadius =>
      BorderRadius.circular(NativeDesktopChromeMetrics.innerDetailCornerRadius);

  /// Selected icon-rail tile: a quiet tonal lift with the accent reserved
  /// for the glyph itself — no rim in dark, one hairline in light.
  static BoxDecoration railSelection(LayoutPalette colors) {
    final dark = colors.isDark;
    return BoxDecoration(
      color: dark ? Colors.white.withAlpha(14) : Colors.white.withAlpha(200),
      borderRadius: BorderRadius.circular(12),
      border: dark
          ? null
          : Border.all(
              color: colors.line.withAlpha(90),
              width: NativeDesktopChromeMetrics.hairline,
            ),
    );
  }

  /// Hover whisper for idle rail tiles and capsule buttons.
  static BoxDecoration hoverPill(LayoutPalette colors, {double radius = 12}) {
    return BoxDecoration(
      color: colors.isDark
          ? Colors.white.withAlpha(8)
          : Colors.black.withAlpha(10),
      borderRadius: BorderRadius.circular(radius),
    );
  }

  /// Floating search capsule in the top band: top-lit glass with a hairline
  /// rim; the focused state trades the rim for the brand accent plus a
  /// faint outer bloom.
  static BoxDecoration capsule(LayoutPalette colors, {bool focused = false}) {
    final dark = colors.isDark;
    return BoxDecoration(
      color: Colors.white.withAlpha(
        dark ? (focused ? 24 : 14) : (focused ? 240 : 190),
      ),
      borderRadius: BorderRadius.circular(
        NativeDesktopChromeMetrics.searchFieldCornerRadius,
      ),
      border: Border.all(
        color: focused
            ? colors.primary.withAlpha(215)
            : dark
            ? Colors.white.withAlpha(26)
            : colors.line.withAlpha(140),
        width: focused ? 1 : NativeDesktopChromeMetrics.hairline,
      ),
      boxShadow: focused
          ? [
              BoxShadow(
                color: colors.primary.withAlpha(40),
                blurRadius: 12,
                spreadRadius: -2,
              ),
            ]
          : [
              BoxShadow(
                color: Colors.black.withAlpha(dark ? 45 : 20),
                blurRadius: 10,
                offset: const Offset(0, 3),
                spreadRadius: -4,
              ),
            ],
    );
  }

  /// Floating menu pane: opaque sheet, hairline rim, soft drop shadow.
  static BoxDecoration menuPane(LayoutPalette colors) {
    return BoxDecoration(
      color: colors.surface,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(
        color: colors.line.withAlpha(colors.isDark ? 120 : 140),
        width: NativeDesktopChromeMetrics.hairline,
      ),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withAlpha(colors.isDark ? 120 : 50),
          blurRadius: 24,
          offset: const Offset(0, 8),
          spreadRadius: -6,
        ),
      ],
    );
  }
}
