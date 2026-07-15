import 'package:flutter/material.dart';

import 'package:flutter_client/src/contracts/appearance/appearance_preset_config.dart';

export 'package:flutter_client/src/contracts/appearance/appearance_preset_config.dart';

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
              ? AppearancePresetIds.licoCrystal
              : AppearancePresetIds.geekLightBlue),
      configs,
      platformBrightness,
    );
    return resolved.copyWith(selectedId: selected.id);
  }

  final baseId = selected.mode == AppearancePresetMode.dark
      ? AppearancePresetIds.licoCrystal
      : AppearancePresetIds.geekLightBlue;
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

Color colorFromAppearanceToken(
  Map<String, String> tokens,
  String token,
  String fallback,
) {
  return _colorFromHex(tokens[token] ?? fallback);
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

Map<String, String> _deriveTokens(
  AppearancePresetMode mode,
  Map<String, String> tokens,
) {
  final isDark = mode == AppearancePresetMode.dark;
  final brand = tokens['brand'] ?? '#2563eb';
  final danger = tokens['danger'] ?? (isDark ? '#fb7185' : '#b91c1c');
  final success = tokens['success'] ?? (isDark ? '#4ade80' : '#15803d');
  final textPrimary =
      tokens['text-primary'] ?? (isDark ? '#f8fafc' : '#0f172a');
  final textMuted = tokens['text-muted'] ?? (isDark ? '#94a3b8' : '#475569');
  final bgBase = tokens['bg-base'] ?? (isDark ? '#0f172a' : '#f8fafc');
  final bgSubtle = tokens['bg-subtle'] ?? (isDark ? '#1f2937' : '#f1f5f9');
  final borderSubtle =
      tokens['border-subtle'] ?? (isDark ? '#334155' : '#cbd5e1');

  return {
    'color-scheme': mode.id,
    'bg-inset': isDark ? '#0b1120' : '#e2e8f0',
    'border-subtle': borderSubtle,
    'border-strong': isDark ? '#475569' : '#94a3b8',
    'text-secondary': isDark ? '#cbd5e1' : '#334155',
    'text-disabled': isDark ? '#64748b' : '#94a3b8',
    'text-on-brand': isDark ? '#06121f' : '#ffffff',
    'text-inverse': isDark ? '#020617' : '#ffffff',
    'brand-muted': isDark ? '#0c4a6e' : '#bfdbfe',
    'accent': 'var(--brand)',
    'info': isDark ? '#22d3ee' : '#0e7490',
    'info-surface': isDark ? '#083344' : '#cffafe',
    'info-border': isDark ? '#155e75' : '#67e8f9',
    'success-surface': isDark ? '#052e16' : '#dcfce7',
    'success-border': isDark ? '#166534' : '#86efac',
    'warning-text': isDark ? '#fde68a' : '#92400e',
    'warning-surface': isDark ? '#422006' : '#fef3c7',
    'warning-border': isDark ? '#854d0e' : '#fcd34d',
    'danger-surface': isDark ? '#4c0519' : '#fee2e2',
    'danger-border': isDark ? '#9f1239' : '#fca5a5',
    'brand-ring': _rgba(brand, isDark ? 0.22 : 0.18),
    'brand-tint': _rgba(brand, isDark ? 0.10 : 0.08),
    'brand-border': _rgba(brand, isDark ? 0.44 : 0.42),
    'brand-glow': _rgba(brand, 0.12),
    'brand-shadow': _rgba(brand, 0.24),
    'danger-tint': _rgba(danger, isDark ? 0.12 : 0.10),
    'success-tint': _rgba(success, isDark ? 0.12 : 0.10),
    'backdrop': isDark ? 'rgba(2, 6, 23, 0.62)' : 'rgba(15, 23, 42, 0.42)',
    'backdrop-strong': isDark
        ? 'rgba(2, 6, 23, 0.74)'
        : 'rgba(15, 23, 42, 0.58)',
    'border-soft': _rgba(borderSubtle, isDark ? 0.55 : 0.32),
    'scrollbar-thumb': _rgba(textMuted, isDark ? 0.38 : 0.42),
    'scrollbar-thumb-hover': _rgba(textPrimary, isDark ? 0.52 : 0.60),
    'shadow-xs': isDark
        ? '0 1px 2px rgba(0, 0, 0, 0.44)'
        : '0 1px 2px rgba(15, 23, 42, 0.06)',
    'shadow-sm': isDark
        ? '0 1px 3px rgba(0, 0, 0, 0.52), 0 1px 2px rgba(0, 0, 0, 0.36)'
        : '0 1px 3px rgba(15, 23, 42, 0.08), 0 1px 2px rgba(15, 23, 42, 0.04)',
    'shadow-md': isDark
        ? '0 4px 12px rgba(0, 0, 0, 0.58), 0 2px 4px rgba(0, 0, 0, 0.36)'
        : '0 4px 12px rgba(15, 23, 42, 0.10), 0 2px 4px rgba(15, 23, 42, 0.05)',
    'shadow-lg': isDark
        ? '0 8px 24px rgba(0, 0, 0, 0.66), 0 4px 8px rgba(0, 0, 0, 0.36)'
        : '0 8px 24px rgba(15, 23, 42, 0.12), 0 4px 8px rgba(15, 23, 42, 0.05)',
    'shadow-xl': isDark
        ? '0 20px 48px rgba(0, 0, 0, 0.74), 0 8px 16px rgba(0, 0, 0, 0.44)'
        : '0 20px 48px rgba(15, 23, 42, 0.16), 0 8px 16px rgba(15, 23, 42, 0.07)',
    'skeleton-base': isDark ? bgSubtle : '#e2e8f0',
    'skeleton-highlight': bgBase,
    ...tokens,
  };
}

Color _colorFromHex(String hex) {
  final normalized = hex.replaceFirst('#', '');
  return Color(int.parse('ff$normalized', radix: 16));
}

String _rgba(String hex, double alpha) {
  final normalized = hex.replaceFirst('#', '');
  final red = int.parse(normalized.substring(0, 2), radix: 16);
  final green = int.parse(normalized.substring(2, 4), radix: 16);
  final blue = int.parse(normalized.substring(4, 6), radix: 16);
  return 'rgba($red, $green, $blue, '
      '${alpha.toStringAsFixed(2)})';
}
