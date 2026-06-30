import 'package:flutter/material.dart';

import 'appearance_preset_config.dart';

class LicoThemeColors extends ThemeExtension<LicoThemeColors> {
  const LicoThemeColors({
    required this.background,
    required this.surface,
    required this.surfaceLow,
    required this.surfaceHigh,
    required this.surfaceHighest,
    required this.line,
    required this.text,
    required this.textMuted,
    required this.primary,
    required this.primaryStrong,
    required this.primaryFixed,
    required this.textOnPrimary,
    required this.success,
    required this.warning,
    required this.error,
  });

  final Color background;
  final Color surface;
  final Color surfaceLow;
  final Color surfaceHigh;
  final Color surfaceHighest;
  final Color line;
  final Color text;
  final Color textMuted;
  final Color primary;
  final Color primaryStrong;
  final Color primaryFixed;
  final Color textOnPrimary;
  final Color success;
  final Color warning;
  final Color error;

  bool get isDark {
    return ThemeData.estimateBrightnessForColor(background) == Brightness.dark;
  }

  @override
  LicoThemeColors copyWith({
    Color? background,
    Color? surface,
    Color? surfaceLow,
    Color? surfaceHigh,
    Color? surfaceHighest,
    Color? line,
    Color? text,
    Color? textMuted,
    Color? primary,
    Color? primaryStrong,
    Color? primaryFixed,
    Color? textOnPrimary,
    Color? success,
    Color? warning,
    Color? error,
  }) {
    return LicoThemeColors(
      background: background ?? this.background,
      surface: surface ?? this.surface,
      surfaceLow: surfaceLow ?? this.surfaceLow,
      surfaceHigh: surfaceHigh ?? this.surfaceHigh,
      surfaceHighest: surfaceHighest ?? this.surfaceHighest,
      line: line ?? this.line,
      text: text ?? this.text,
      textMuted: textMuted ?? this.textMuted,
      primary: primary ?? this.primary,
      primaryStrong: primaryStrong ?? this.primaryStrong,
      primaryFixed: primaryFixed ?? this.primaryFixed,
      textOnPrimary: textOnPrimary ?? this.textOnPrimary,
      success: success ?? this.success,
      warning: warning ?? this.warning,
      error: error ?? this.error,
    );
  }

  @override
  LicoThemeColors lerp(ThemeExtension<LicoThemeColors>? other, double t) {
    if (other is! LicoThemeColors) {
      return this;
    }
    return LicoThemeColors(
      background: Color.lerp(background, other.background, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surfaceLow: Color.lerp(surfaceLow, other.surfaceLow, t)!,
      surfaceHigh: Color.lerp(surfaceHigh, other.surfaceHigh, t)!,
      surfaceHighest: Color.lerp(surfaceHighest, other.surfaceHighest, t)!,
      line: Color.lerp(line, other.line, t)!,
      text: Color.lerp(text, other.text, t)!,
      textMuted: Color.lerp(textMuted, other.textMuted, t)!,
      primary: Color.lerp(primary, other.primary, t)!,
      primaryStrong: Color.lerp(primaryStrong, other.primaryStrong, t)!,
      primaryFixed: Color.lerp(primaryFixed, other.primaryFixed, t)!,
      textOnPrimary: Color.lerp(textOnPrimary, other.textOnPrimary, t)!,
      success: Color.lerp(success, other.success, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      error: Color.lerp(error, other.error, t)!,
    );
  }
}

extension LicoThemeContext on BuildContext {
  LicoThemeColors get licoColors {
    return Theme.of(this).extension<LicoThemeColors>() ??
        licoColorsFor(AppearancePresetIds.licoliteCrystal);
  }
}

LicoThemeColors licoColorsFor(
  String presetId, {
  List<AppearancePresetConfig> presets = builtInAppearancePresetConfigs,
  Brightness platformBrightness = Brightness.light,
}) {
  final resolved = resolveAppearancePresetConfig(
    presetId,
    presets,
    platformBrightness,
  );
  final tokens = resolved.tokens;
  return LicoThemeColors(
    background: colorFromAppearanceToken(tokens, 'bg-base', '#f8fafc'),
    surface: colorFromAppearanceToken(tokens, 'bg-surface', '#ffffff'),
    surfaceLow: colorFromAppearanceToken(tokens, 'bg-subtle', '#f1f5f9'),
    surfaceHigh: colorFromAppearanceToken(tokens, 'brand-subtle', '#dbeafe'),
    surfaceHighest: colorFromAppearanceToken(tokens, 'brand-muted', '#bfdbfe'),
    line: colorFromAppearanceToken(tokens, 'border-subtle', '#cbd5e1'),
    text: colorFromAppearanceToken(tokens, 'text-primary', '#0f172a'),
    textMuted: colorFromAppearanceToken(tokens, 'text-muted', '#475569'),
    primary: colorFromAppearanceToken(tokens, 'brand', '#2563eb'),
    primaryStrong: colorFromAppearanceToken(tokens, 'brand-strong', '#1d4ed8'),
    primaryFixed: colorFromAppearanceToken(tokens, 'brand-subtle', '#dbeafe'),
    textOnPrimary: colorFromAppearanceToken(tokens, 'text-on-brand', '#ffffff'),
    success: colorFromAppearanceToken(tokens, 'success', '#15803d'),
    warning: colorFromAppearanceToken(tokens, 'warning', '#b45309'),
    error: colorFromAppearanceToken(tokens, 'danger', '#b91c1c'),
  );
}

ThemeData buildLicoTheme({
  String presetId = AppearancePresetIds.licoliteCrystal,
  List<AppearancePresetConfig> presets = builtInAppearancePresetConfigs,
  Brightness platformBrightness = Brightness.dark,
}) {
  final colors = licoColorsFor(
    presetId,
    presets: presets,
    platformBrightness: platformBrightness,
  );
  final base = colors.isDark
      ? ThemeData.dark(useMaterial3: true)
      : ThemeData.light(useMaterial3: true);
  final textTheme = base.textTheme.apply(
    bodyColor: colors.text,
    displayColor: colors.text,
  );

  return base.copyWith(
    scaffoldBackgroundColor: colors.background,
    textTheme: textTheme,
    colorScheme: colors.isDark
        ? ColorScheme.dark(
            surface: colors.surface,
            primary: colors.primary,
            onPrimary: colors.textOnPrimary,
            secondary: colors.primaryStrong,
            onSecondary: colors.textOnPrimary,
            error: colors.error,
            onError: const Color(0xFF111827),
            onSurface: colors.text,
            surfaceContainerHighest: colors.surfaceHighest,
          )
        : ColorScheme.light(
            surface: colors.surface,
            primary: colors.primary,
            onPrimary: colors.textOnPrimary,
            secondary: colors.primaryStrong,
            onSecondary: colors.textOnPrimary,
            error: colors.error,
            onError: Colors.white,
            onSurface: colors.text,
            surfaceContainerHighest: colors.surfaceHighest,
          ),
    extensions: [colors],
    cardTheme: CardThemeData(
      color: colors.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: colors.line),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: colors.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: colors.line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: colors.line),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: colors.primary, width: 1.5),
      ),
    ),
  );
}
