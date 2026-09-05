import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/appearance/appearance_preset_config.dart';

ThemeMode themeModeForAppearance(
  String id,
  List<AppearancePresetConfig> configs,
) {
  final selected = findAppearancePresetConfig(id, configs);
  return switch (selected.mode) {
    AppearancePresetMode.system => ThemeMode.system,
    AppearancePresetMode.dark => ThemeMode.dark,
    AppearancePresetMode.light => ThemeMode.light,
  };
}

/// Whether the selected preset resolves to a dark appearance.
///
/// When [selectedId] follows the system, [platformBrightness] decides the
/// resolved mode so the day/night toggle reflects what the user currently sees.
bool isResolvedAppearanceDark(
  String selectedId,
  List<AppearancePresetConfig> configs,
  Brightness platformBrightness,
) {
  return resolveAppearancePresetConfig(
        selectedId,
        configs,
        platformBrightness,
      ).mode ==
      AppearancePresetMode.dark;
}

/// Maps an explicit day/night choice to the built-in fixed preset id.
String appearancePresetIdForBrightness(bool dark) {
  return dark
      ? AppearancePresetIds.licoSoda
      : AppearancePresetIds.licoSodaLight;
}

/// Maps a brightness-mode choice to the preset id that should be persisted.
///
/// Light and dark keep the current preset when it already matches that mode;
/// otherwise they fall back to the built-in fixed preset for that mode.
String appearancePresetIdForBrightnessSelection(
  AppearanceBrightnessSelection selection,
  String currentId,
  List<AppearancePresetConfig> configs,
) {
  return switch (selection) {
    AppearanceBrightnessSelection.system => AppearancePresetIds.defaultSystem,
    AppearanceBrightnessSelection.light => () {
      final current = findAppearancePresetConfig(currentId, configs);
      if (current.mode == AppearancePresetMode.light) {
        return currentId;
      }
      return AppearancePresetIds.licoSodaLight;
    }(),
    AppearanceBrightnessSelection.dark => () {
      final current = findAppearancePresetConfig(currentId, configs);
      if (current.mode == AppearancePresetMode.dark) {
        return currentId;
      }
      return AppearancePresetIds.licoSoda;
    }(),
  };
}

/// Presets offered in the appearance picker for the current brightness.
///
/// [dark] reflects the resolved day/night mode. System-following presets are
/// excluded; fixed presets are limited to the active mode so a light toggle
/// never lists dark themes and vice versa.
List<AppearancePresetConfig> selectableAppearancePresetsForBrightness(
  List<AppearancePresetConfig> configs,
  bool dark,
) {
  return configs
      .where(
        (config) =>
            !AppearancePresetIds.resolutionOnly.contains(config.id) &&
            config.mode != AppearancePresetMode.system &&
            (dark
                ? config.mode == AppearancePresetMode.dark
                : config.mode == AppearancePresetMode.light),
      )
      .toList(growable: false);
}

ResolvedAppearancePreset resolveAppearancePresetConfig(
  String selectedId,
  List<AppearancePresetConfig> configs,
  Brightness platformBrightness,
) {
  if (configs.isEmpty) {
    throw StateError('No appearance preset configs are available');
  }
  final selected = findAppearancePresetConfig(selectedId, configs);
  if (selected.mode == AppearancePresetMode.system) {
    final resolvedId = platformBrightness == Brightness.dark
        ? selected.darkPresetId
        : selected.lightPresetId;
    final resolved = resolveAppearancePresetConfig(
      resolvedId ??
          (platformBrightness == Brightness.dark
              ? AppearancePresetIds.licoSoda
              : AppearancePresetIds.licoSodaLight),
      configs,
      platformBrightness,
    );
    return resolved.copyWith(selectedId: selected.id);
  }

  final baseId = selected.mode == AppearancePresetMode.dark
      ? AppearancePresetIds.licoSoda
      : AppearancePresetIds.licoSodaLight;
  final base = selected.id == baseId
      ? null
      : findAppearancePresetConfig(baseId, builtInAppearancePresetConfigs);
  final baseTokens = base?.mode == selected.mode
      ? _deriveTokens(base!.mode, base.tokens)
      : <String, String>{};
  final tokens = _deriveTokens(selected.mode, {
    ...baseTokens,
    ...selected.tokens,
  });

  return ResolvedAppearancePreset(
    selectedId: selectedId,
    resolvedId: selected.id,
    mode: selected.mode,
    tokens: tokens,
  );
}

/// Resolves one appearance token to a [Color].
///
/// Accepts `#rrggbb` and `rgba(r, g, b, a)`. Both forms are permitted by the
/// preset schema, so every token the runtime reads must parse through here
/// rather than through a hex-only helper.
Color colorFromAppearanceToken(
  Map<String, String> tokens,
  String token,
  String fallback,
) {
  return _colorFromToken(tokens[token] ?? fallback, fallback);
}

class ResolvedAppearancePreset {
  const ResolvedAppearancePreset({
    required this.selectedId,
    required this.resolvedId,
    required this.mode,
    required this.tokens,
  });

  final String selectedId;
  final String resolvedId;
  final AppearancePresetMode mode;
  final Map<String, String> tokens;

  ResolvedAppearancePreset copyWith({String? selectedId}) {
    return ResolvedAppearancePreset(
      selectedId: selectedId ?? this.selectedId,
      resolvedId: resolvedId,
      mode: mode,
      tokens: tokens,
    );
  }
}

/// Fills in every runtime role a preset did not declare.
///
/// This is the compatibility layer that lets a preset authored against an
/// earlier schema keep working: the roles introduced later are derived from
/// the roles it does declare instead of being rejected. Every value emitted
/// here must be parseable by [colorFromAppearanceToken] — no `var(--x)`
/// indirection and no CSS shadow shorthand.
Map<String, String> _deriveTokens(
  AppearancePresetMode mode,
  Map<String, String> tokens,
) {
  final isDark = mode == AppearancePresetMode.dark;
  final brand = tokens['brand'] ?? (isDark ? '#e1ec28' : '#d9e320');
  final accent = tokens['accent'] ?? (isDark ? '#21dcf1' : '#007d8a');
  final textPrimary =
      tokens['text-primary'] ?? (isDark ? '#f4f4f7' : '#1a1a20');
  final bgSubtle = tokens['bg-subtle'] ?? (isDark ? '#2a2a2f' : '#eeeef1');
  final bgRaised = tokens['bg-raised'] ?? (isDark ? '#3a3a3f' : '#ffffff');
  final borderSubtle =
      tokens['border-subtle'] ?? (isDark ? '#323337' : '#dbdce0');

  return {
    'color-scheme': mode.id,

    // Neutral depth. `bg-raised` is the highest neutral step and must never
    // be substituted by a brand tint.
    'bg-inset': isDark ? '#040405' : '#e7e7ea',
    'bg-raised': bgRaised,
    'border-subtle': borderSubtle,
    'border-strong': isDark ? '#56565b' : '#b0b0b6',

    // Text ramp.
    'text-secondary': isDark ? '#cccdd0' : '#4f4f55',
    'text-disabled': isDark ? '#6c6c70' : '#9d9ea3',
    'text-on-brand': isDark ? '#171800' : '#1b1d00',

    // Brand is fill-and-mark. `brand-border` is the mandatory hairline for a
    // brand fill, whose own contrast against the surface can be below 3:1.
    'brand-border': isDark ? '#878d24' : '#bfc744',

    // Accent carries interaction and must stay legible as text.
    'accent': accent,
    'accent-strong': isDark ? '#87effe' : '#0d5f68',
    'accent-surface': isDark ? '#1d3339' : '#deeef0',
    'accent-border': isDark ? '#1e838f' : '#67c8d6',
    'text-on-accent': isDark ? '#00191e' : '#ffffff',

    // State washes, composited over whatever surface is underneath.
    'hover-overlay': _rgba(textPrimary, isDark ? 0.07 : 0.05),
    'pressed-overlay': _rgba(textPrimary, isDark ? 0.12 : 0.09),
    'selected-surface': bgSubtle,

    // Luminous brand and interaction moments.
    'brand-glow': _rgba(brand, isDark ? 0.22 : 0.30),
    'accent-glow': _rgba(accent, isDark ? 0.26 : 0.22),

    // Loading placeholders.
    'skeleton-base': bgSubtle,
    'skeleton-highlight': bgRaised,

    // Retained for preset authors that tint marks with the emphatic brand.
    'brand-muted': tokens['brand-strong'] ?? (isDark ? '#f3fe4f' : '#878e1f'),
    'brand-subtle': tokens['brand-subtle'] ?? (isDark ? '#2e2f21' : '#f5f8c5'),
    'brand': brand,

    ...tokens,
  };
}

Color _colorFromToken(String value, String fallback) {
  final parsed = _tryParseColor(value);
  if (parsed != null) {
    return parsed;
  }
  return _tryParseColor(fallback) ?? const Color(0xFF000000);
}

Color? _tryParseColor(String value) {
  final trimmed = value.trim();
  if (trimmed.startsWith('#')) {
    final normalized = trimmed.substring(1);
    if (normalized.length != 6) {
      return null;
    }
    final parsed = int.tryParse(normalized, radix: 16);
    if (parsed == null) {
      return null;
    }
    return Color(0xFF000000 | parsed);
  }
  final rgba = _rgbaPattern.firstMatch(trimmed);
  if (rgba == null) {
    return null;
  }
  final red = int.parse(rgba.group(1)!);
  final green = int.parse(rgba.group(2)!);
  final blue = int.parse(rgba.group(3)!);
  final alpha = double.parse(rgba.group(4)!);
  if (red > 255 || green > 255 || blue > 255 || alpha < 0 || alpha > 1) {
    return null;
  }
  return Color.fromRGBO(red, green, blue, alpha);
}

String _rgba(String hex, double alpha) {
  final normalized = hex.replaceFirst('#', '');
  final red = int.parse(normalized.substring(0, 2), radix: 16);
  final green = int.parse(normalized.substring(2, 4), radix: 16);
  final blue = int.parse(normalized.substring(4, 6), radix: 16);
  return 'rgba($red, $green, $blue, ${alpha.toStringAsFixed(2)})';
}

final _rgbaPattern = RegExp(
  r'^rgba\(\s*(\d{1,3})\s*,\s*(\d{1,3})\s*,\s*(\d{1,3})\s*,\s*(0|1|0?\.\d+)\s*\)$',
);
