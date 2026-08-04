import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/shared/ui/theme_colors.dart';

/// The client's depth scale.
///
/// Depth is expressed by three things working together: a neutral surface
/// step, a hairline rim, and — only for genuinely floating layers — a shadow.
/// Feature code must not compose its own `BoxShadow` lists.
///
/// The three layers are:
///
/// * **L0 window** — `background`. No rim, no shadow.
/// * **L1 content** — `surface` with a `line` rim. Shadow only where the card
///   stands off the window edge.
/// * **L2 floating** — `surfaceRaised` with a `line` rim and a real shadow.
///   Menus, popovers, dialogs, drag proxies.
///
/// Light mode carries more of the depth signal in shadow because its surface
/// steps are compressed near white; dark mode carries more of it in tone.
enum LicoElevation {
  /// Flush with its parent. Rows, list items, inline chips.
  flat,

  /// A content card resting on the window background.
  card,

  /// A floating layer above content: popover, menu, dropdown.
  raised,

  /// A modal layer above everything: dialog, sheet.
  overlay,
}

extension LicoElevationTokens on LicoElevation {
  /// The shadow for this layer, or an empty list when the layer is flush.
  List<BoxShadow> shadows(LicoThemeColors colors) {
    final dark = colors.isDark;
    return switch (this) {
      LicoElevation.flat => const <BoxShadow>[],
      LicoElevation.card => <BoxShadow>[
        BoxShadow(
          color: Colors.black.withValues(alpha: dark ? 0.24 : 0.06),
          blurRadius: 16,
          offset: const Offset(0, 4),
          spreadRadius: -6,
        ),
      ],
      LicoElevation.raised => <BoxShadow>[
        BoxShadow(
          color: Colors.black.withValues(alpha: dark ? 0.34 : 0.10),
          blurRadius: 24,
          offset: const Offset(0, 8),
          spreadRadius: -4,
        ),
        BoxShadow(
          color: Colors.black.withValues(alpha: dark ? 0.22 : 0.05),
          blurRadius: 6,
          offset: const Offset(0, 2),
        ),
      ],
      LicoElevation.overlay => <BoxShadow>[
        BoxShadow(
          color: Colors.black.withValues(alpha: dark ? 0.46 : 0.16),
          blurRadius: 48,
          offset: const Offset(0, 20),
          spreadRadius: -8,
        ),
        BoxShadow(
          color: Colors.black.withValues(alpha: dark ? 0.28 : 0.07),
          blurRadius: 12,
          offset: const Offset(0, 4),
        ),
      ],
    };
  }

  /// The neutral surface fill for this layer.
  Color surface(LicoThemeColors colors) {
    return switch (this) {
      LicoElevation.flat => colors.surface,
      LicoElevation.card => colors.surface,
      LicoElevation.raised => colors.surfaceRaised,
      LicoElevation.overlay => colors.surfaceRaised,
    };
  }
}

/// The scrim behind a modal layer.
Color licoScrimColor(LicoThemeColors colors) {
  return Colors.black.withValues(alpha: colors.isDark ? 0.62 : 0.42);
}
