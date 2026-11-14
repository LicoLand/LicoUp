import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/shared/ui/theme_colors.dart';

/// Pixel-stable visual roles shared by canonical and agent conversations.
///
/// These roles name intentional conversation chrome that predates the general
/// appearance-preset state washes. Keeping the exact channel values here lets
/// both conversation projections share the same semantics without restating
/// raw white/black overlays in feature widgets.
abstract final class ConversationVisualTokens {
  /// Default fill behind messaging identity-mark wells. Dark messaging
  /// surfaces use pure black; light surfaces keep the neutral recessed well.
  static Color identityWellFill(LicoThemeColors colors) =>
      colors.isDark ? Colors.black : colors.surfaceLow;

  /// Brand mark used to identify a canonical group conversation.
  static Color groupIdentityMark(LicoThemeColors colors) => colors.primary;

  /// Selected option fill used inside detached conversation menus.
  static Color selectedOptionFill(LicoThemeColors colors) =>
      colors.selectionInk.withValues(alpha: colors.isDark ? 0.16 : 0.10);

  /// Unread/reminder count badge: the deep accent violet in dark presets,
  /// the taro brand violet in light presets — always white numerals.
  static Color unreadBadgeFill(LicoThemeColors colors) => colors.isDark
      ? licoDeepViolet(colors.accent, lightness: 0.38)
      : colors.primary;

  /// Recessed black veil behind the Acativa capsule stadium.
  static Color acativaStadiumVeil(LicoThemeColors colors) =>
      colors.isDark ? const Color(0x6E000000) : const Color(0x24000000);
}
