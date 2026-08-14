import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/shared/ui/theme_colors.dart';

/// Pixel-stable visual roles shared by canonical and agent conversations.
///
/// These roles name intentional conversation chrome that predates the general
/// appearance-preset state washes. Keeping the exact channel values here lets
/// both conversation projections share the same semantics without restating
/// raw white/black overlays in feature widgets.
abstract final class ConversationVisualTokens {
  /// Default fill behind circular messaging identity marks. Dark messaging
  /// surfaces use pure black; light surfaces keep the neutral recessed well.
  static Color circularIdentityWellFill(LicoThemeColors colors) =>
      colors.isDark ? Colors.black : colors.surfaceLow;

  /// Brand mark used to identify a canonical group conversation.
  static Color groupIdentityMark(LicoThemeColors colors) => colors.primary;

  /// Quiet row hover used by conversation-list items.
  static Color quietRowHover(LicoThemeColors colors) =>
      colors.isDark ? const Color(0x08FFFFFF) : const Color(0x08000000);

  /// Selected option fill used inside detached conversation menus.
  static Color selectedOptionFill(LicoThemeColors colors) =>
      colors.isDark ? const Color(0x0AFFFFFF) : const Color(0x08000000);

  /// Recessed black veil behind the Adaptive Flywheel capsule stadium.
  static Color adaptiveFlywheelStadiumVeil(LicoThemeColors colors) =>
      colors.isDark ? const Color(0x6E000000) : const Color(0x24000000);
}
