import 'package:flutter/material.dart';

typedef AppearancePresetId = String;

const appearancePresetSchemaVersion =
    'v0.0.1:client-desktop:appearance-preset-1';

enum AppearancePresetMode {
  system('system'),
  light('light'),
  dark('dark');

  const AppearancePresetMode(this.id);

  final String id;

  static AppearancePresetMode? parse(String value) {
    for (final mode in values) {
      if (mode.id == value) {
        return mode;
      }
    }
    return null;
  }
}

abstract final class AppearancePresetIds {
  static const defaultSystem = 'default-system';
  static const licoliteCrystal = 'licolite-crystal';
  static const geekLightBlue = 'geek-light-blue';
  static const sunsetEmber = 'sunset-ember';
  static const tokyoNight = 'tokyo-night';
  static const monokai = 'monokai';
  static const cyberpunk = 'cyberpunk';
  static const cappuccinoDark = 'cappuccino-dark';

  static const builtIn = [
    defaultSystem,
    licoliteCrystal,
    geekLightBlue,
    sunsetEmber,
    tokyoNight,
    monokai,
    cyberpunk,
    cappuccinoDark,
  ];
}

class AppearancePresetConfig {
  const AppearancePresetConfig({
    required this.schemaVersion,
    required this.id,
    required this.label,
    required this.mode,
    this.lightPresetId,
    this.darkPresetId,
    this.tokens = const {},
  });

  factory AppearancePresetConfig.fromJson(Object? value) {
    final result = validateAppearancePresetConfig(value);
    if (!result.ok) {
      throw FormatException(result.errors.join('; '));
    }
    return result.config!;
  }

  final String schemaVersion;
  final AppearancePresetId id;
  final Map<String, String> label;
  final AppearancePresetMode mode;
  final AppearancePresetId? lightPresetId;
  final AppearancePresetId? darkPresetId;
  final Map<String, String> tokens;

  String labelFor([String locale = 'en']) {
    return label[locale] ?? label['en'] ?? id;
  }
}

class AppearancePresetValidationResult {
  const AppearancePresetValidationResult._({
    required this.ok,
    required this.errors,
    this.config,
  });

  const AppearancePresetValidationResult.ok(AppearancePresetConfig config)
    : this._(ok: true, errors: const [], config: config);

  const AppearancePresetValidationResult.error(List<String> errors)
    : this._(ok: false, errors: errors);

  final bool ok;
  final List<String> errors;
  final AppearancePresetConfig? config;
}

const builtInAppearancePresetAssetPaths = [
  'assets/appearance-presets/default-system.json',
  'assets/appearance-presets/licolite-crystal.json',
  'assets/appearance-presets/geek-light-blue.json',
  'assets/appearance-presets/sunset-ember.json',
  'assets/appearance-presets/tokyo-night.json',
  'assets/appearance-presets/monokai.json',
  'assets/appearance-presets/cyberpunk.json',
  'assets/appearance-presets/cappuccino-dark.json',
];

const builtInAppearancePresetConfigs = [
  AppearancePresetConfig(
    schemaVersion: appearancePresetSchemaVersion,
    id: AppearancePresetIds.defaultSystem,
    label: {'en': 'System Default', 'zh-CN': '跟随系统'},
    mode: AppearancePresetMode.system,
    lightPresetId: AppearancePresetIds.geekLightBlue,
    darkPresetId: AppearancePresetIds.licoliteCrystal,
  ),
  AppearancePresetConfig(
    schemaVersion: appearancePresetSchemaVersion,
    id: AppearancePresetIds.licoliteCrystal,
    label: {'en': 'LicoLite Crystal', 'zh-CN': '晶体原色'},
    mode: AppearancePresetMode.dark,
    tokens: {
      'bg-base': '#0a0a14',
      'bg-surface': '#10101c',
      'bg-subtle': '#161624',
      'bg-inset': '#06060e',
      'border-subtle': '#2a2a40',
      'border-strong': '#3d3d5a',
      'text-primary': '#ede6d6',
      'text-secondary': '#b0a899',
      'text-muted': '#7a8ea8',
      'text-disabled': '#4a4a64',
      'text-on-brand': '#0a0a14',
      'brand': '#c9a96e',
      'brand-strong': '#f0d28c',
      'brand-subtle': '#1a1510',
      'brand-muted': '#3a3020',
      'info': '#4fc3f7',
      'info-surface': '#0a1a28',
      'info-border': '#1a3a55',
      'success': '#80deaa',
      'success-surface': '#0a1e16',
      'success-border': '#1a4a35',
      'warning': '#f0d28c',
      'warning-text': '#f5e0a8',
      'warning-surface': '#1e1a0e',
      'warning-border': '#6a5530',
      'danger': '#f07878',
      'danger-surface': '#1e0c0c',
      'danger-border': '#6a2a2a',
    },
  ),
  AppearancePresetConfig(
    schemaVersion: appearancePresetSchemaVersion,
    id: AppearancePresetIds.geekLightBlue,
    label: {'en': 'Geek Light Blue', 'zh-CN': '极客浅蓝'},
    mode: AppearancePresetMode.light,
    tokens: {
      'bg-base': '#f5f9ff',
      'bg-surface': '#ffffff',
      'bg-subtle': '#eaf3ff',
      'bg-inset': '#dbeafe',
      'border-subtle': '#bfdbfe',
      'border-strong': '#60a5fa',
      'text-primary': '#0b1220',
      'text-secondary': '#1e3a8a',
      'text-muted': '#315a8a',
      'text-disabled': '#7aa2cc',
      'text-on-brand': '#ffffff',
      'brand': '#2563eb',
      'brand-strong': '#1d4ed8',
      'brand-subtle': '#dbeafe',
      'brand-muted': '#bfdbfe',
      'info': '#0e7490',
      'info-surface': '#cffafe',
      'info-border': '#67e8f9',
      'success': '#15803d',
      'success-surface': '#dcfce7',
      'success-border': '#86efac',
      'warning': '#b45309',
      'warning-text': '#92400e',
      'warning-surface': '#fef3c7',
      'warning-border': '#fcd34d',
      'danger': '#b91c1c',
      'danger-surface': '#fee2e2',
      'danger-border': '#fca5a5',
    },
  ),
  AppearancePresetConfig(
    schemaVersion: appearancePresetSchemaVersion,
    id: AppearancePresetIds.sunsetEmber,
    label: {'en': 'Sunset Ember', 'zh-CN': '落日余烬'},
    mode: AppearancePresetMode.dark,
    tokens: {
      'bg-base': '#18181b',
      'bg-surface': '#1f1f23',
      'bg-subtle': '#292524',
      'bg-inset': '#111111',
      'border-subtle': '#44403c',
      'border-strong': '#57534e',
      'text-primary': '#fafaf9',
      'text-secondary': '#d6d3d1',
      'text-muted': '#a8a29e',
      'text-disabled': '#78716c',
      'text-on-brand': '#111827',
      'brand': '#f97316',
      'brand-strong': '#fb923c',
      'brand-subtle': '#431407',
      'brand-muted': '#7c2d12',
      'info': '#38bdf8',
      'info-surface': '#082f49',
      'info-border': '#075985',
      'success': '#4ade80',
      'success-surface': '#052e16',
      'success-border': '#166534',
      'warning': '#facc15',
      'warning-text': '#fde68a',
      'warning-surface': '#422006',
      'warning-border': '#854d0e',
      'danger': '#fb7185',
      'danger-surface': '#4c0519',
      'danger-border': '#9f1239',
    },
  ),
  AppearancePresetConfig(
    schemaVersion: appearancePresetSchemaVersion,
    id: AppearancePresetIds.tokyoNight,
    label: {'en': 'Tokyo Night', 'zh-CN': '东京之夜'},
    mode: AppearancePresetMode.dark,
    tokens: {
      'bg-base': '#1a1b26',
      'bg-surface': '#24283b',
      'bg-subtle': '#292e42',
      'bg-inset': '#16161e',
      'border-subtle': '#414868',
      'border-strong': '#565f89',
      'text-primary': '#c0caf5',
      'text-secondary': '#a9b1d6',
      'text-muted': '#9aa5ce',
      'text-disabled': '#565f89',
      'text-on-brand': '#11131f',
      'brand': '#7aa2f7',
      'brand-strong': '#bb9af7',
      'brand-subtle': '#1f2335',
      'brand-muted': '#2f3658',
      'info': '#7dcfff',
      'info-surface': '#123145',
      'info-border': '#2f628e',
      'success': '#9ece6a',
      'success-surface': '#1f3524',
      'success-border': '#3d6b3d',
      'warning': '#e0af68',
      'warning-text': '#ffe4a6',
      'warning-surface': '#3a2b17',
      'warning-border': '#8f6b34',
      'danger': '#f7768e',
      'danger-surface': '#3d1f2a',
      'danger-border': '#8c4351',
    },
  ),
  AppearancePresetConfig(
    schemaVersion: appearancePresetSchemaVersion,
    id: AppearancePresetIds.monokai,
    label: {'en': 'Monokai', 'zh-CN': 'Monokai'},
    mode: AppearancePresetMode.dark,
    tokens: {
      'bg-base': '#272822',
      'bg-surface': '#2d2e28',
      'bg-subtle': '#3e3d32',
      'bg-inset': '#1e1f1c',
      'border-subtle': '#5a594d',
      'border-strong': '#75715e',
      'text-primary': '#f8f8f2',
      'text-secondary': '#e6db74',
      'text-muted': '#cfcfc2',
      'text-disabled': '#8f8b75',
      'text-on-brand': '#11130c',
      'brand': '#a6e22e',
      'brand-strong': '#66d9ef',
      'brand-subtle': '#263b14',
      'brand-muted': '#3f5a1f',
      'info': '#66d9ef',
      'info-surface': '#12383d',
      'info-border': '#2f7b86',
      'success': '#a6e22e',
      'success-surface': '#20340f',
      'success-border': '#5f8d20',
      'warning': '#fd971f',
      'warning-text': '#ffdca6',
      'warning-surface': '#3d260d',
      'warning-border': '#a86517',
      'danger': '#f92672',
      'danger-surface': '#421327',
      'danger-border': '#a61b4d',
    },
  ),
  AppearancePresetConfig(
    schemaVersion: appearancePresetSchemaVersion,
    id: AppearancePresetIds.cyberpunk,
    label: {'en': 'Cyberpunk', 'zh-CN': '赛博朋克'},
    mode: AppearancePresetMode.dark,
    tokens: {
      'bg-base': '#080816',
      'bg-surface': '#10142b',
      'bg-subtle': '#181c3a',
      'bg-inset': '#05050f',
      'border-subtle': '#2d3563',
      'border-strong': '#4b5bb2',
      'text-primary': '#f4f7ff',
      'text-secondary': '#c9d4ff',
      'text-muted': '#9aa7c7',
      'text-disabled': '#657094',
      'text-on-brand': '#031018',
      'brand': '#00e5ff',
      'brand-strong': '#5cf4ff',
      'brand-subtle': '#08233c',
      'brand-muted': '#12415f',
      'info': '#00e5ff',
      'info-surface': '#062a3d',
      'info-border': '#0e7490',
      'success': '#39ff88',
      'success-surface': '#09351f',
      'success-border': '#15803d',
      'warning': '#fcee09',
      'warning-text': '#fff6a3',
      'warning-surface': '#3d3303',
      'warning-border': '#a88600',
      'danger': '#ff2a6d',
      'danger-surface': '#4a0a24',
      'danger-border': '#b8174b',
    },
  ),
  AppearancePresetConfig(
    schemaVersion: appearancePresetSchemaVersion,
    id: AppearancePresetIds.cappuccinoDark,
    label: {'en': 'Cappuccino', 'zh-CN': '卡布奇诺'},
    mode: AppearancePresetMode.dark,
    tokens: {
      'bg-base': '#11111b',
      'bg-surface': '#1e1e2e',
      'bg-subtle': '#313244',
      'bg-inset': '#181825',
      'border-subtle': '#45475a',
      'border-strong': '#585b70',
      'text-primary': '#cdd6f4',
      'text-secondary': '#bac2de',
      'text-muted': '#a6adc8',
      'text-disabled': '#6c7086',
      'text-on-brand': '#11111b',
      'brand': '#cba6f7',
      'brand-strong': '#f5c2e7',
      'brand-subtle': '#302d47',
      'brand-muted': '#45415f',
      'info': '#89b4fa',
      'info-surface': '#1f2d4a',
      'info-border': '#3d5f99',
      'success': '#a6e3a1',
      'success-surface': '#213921',
      'success-border': '#4d7f4c',
      'warning': '#f9e2af',
      'warning-text': '#fff1bf',
      'warning-surface': '#3f331d',
      'warning-border': '#8b6f3f',
      'danger': '#f38ba8',
      'danger-surface': '#412437',
      'danger-border': '#8e3d5c',
    },
  ),
];

AppearancePresetValidationResult validateAppearancePresetConfig(Object? value) {
  final errors = <String>[];
  if (value is! Map) {
    return const AppearancePresetValidationResult.error([
      'config must be a JSON object',
    ]);
  }

  final rawSchemaVersion = value['schemaVersion'];
  final schemaVersion = rawSchemaVersion == 1
      ? appearancePresetSchemaVersion
      : rawSchemaVersion;
  if (schemaVersion != appearancePresetSchemaVersion) {
    errors.add('schemaVersion must be $appearancePresetSchemaVersion');
  }

  final id = value['id'];
  if (id is! String || !_idPattern.hasMatch(id)) {
    errors.add('id must be kebab-case and 2-64 characters');
  }

  final rawLabel = value['label'];
  final label = <String, String>{};
  if (rawLabel is Map) {
    for (final entry in rawLabel.entries) {
      if (entry.key is String && entry.value is String) {
        label[entry.key as String] = entry.value as String;
      }
    }
  }
  if ((label['en'] ?? '').isEmpty || (label['zh-CN'] ?? '').isEmpty) {
    errors.add('label.en and label.zh-CN are required');
  }

  final mode = AppearancePresetMode.parse((value['mode'] ?? '').toString());
  if (mode == null) {
    errors.add('mode must be system, light, or dark');
  }

  String? lightPresetId;
  String? darkPresetId;
  if (mode == AppearancePresetMode.system) {
    final rawLightPresetId = value['lightPresetId'];
    final rawDarkPresetId = value['darkPresetId'];
    if (rawLightPresetId is String && rawLightPresetId.isNotEmpty) {
      lightPresetId = rawLightPresetId;
    }
    if (rawDarkPresetId is String && rawDarkPresetId.isNotEmpty) {
      darkPresetId = rawDarkPresetId;
    }
    if (lightPresetId == null || darkPresetId == null) {
      errors.add('system presets require lightPresetId and darkPresetId');
    }
  }

  final tokens = <String, String>{};
  final rawTokens = value['tokens'];
  if (mode != null && mode != AppearancePresetMode.system) {
    if (rawTokens is! Map) {
      errors.add('fixed presets require tokens');
    } else {
      for (final entry in rawTokens.entries) {
        final key = entry.key;
        final tokenValue = entry.value;
        if (key is! String || !_tokenNamePattern.hasMatch(key)) {
          errors.add('tokens.$key has an invalid token name');
          continue;
        }
        if (tokenValue is! String ||
            !_allowedTokenValuePattern.hasMatch(tokenValue)) {
          errors.add('tokens.$key has an invalid CSS token value');
          continue;
        }
        tokens[key] = tokenValue;
      }
      for (final token in _requiredRuntimeTokens) {
        if (!_hexColorPattern.hasMatch(tokens[token] ?? '')) {
          errors.add('tokens.$token must be a 6-digit hex color');
        }
      }
    }
  } else if (rawTokens is Map) {
    for (final entry in rawTokens.entries) {
      if (entry.key is String && entry.value is String) {
        tokens[entry.key as String] = entry.value as String;
      }
    }
  }

  if (errors.isNotEmpty) {
    return AppearancePresetValidationResult.error(errors);
  }

  return AppearancePresetValidationResult.ok(
    AppearancePresetConfig(
      schemaVersion: schemaVersion as String,
      id: id as String,
      label: Map.unmodifiable(label),
      mode: mode!,
      lightPresetId: lightPresetId,
      darkPresetId: darkPresetId,
      tokens: Map.unmodifiable(tokens),
    ),
  );
}

List<AppearancePresetConfig> mergeAppearancePresetConfigs([
  Iterable<AppearancePresetConfig> customConfigs = const [],
]) {
  final byId = <String, AppearancePresetConfig>{};
  for (final config in builtInAppearancePresetConfigs) {
    byId[config.id] = config;
  }
  for (final config in customConfigs) {
    byId[config.id] = config;
  }
  return List.unmodifiable(byId.values);
}

AppearancePresetConfig findAppearancePresetConfig(
  String id,
  List<AppearancePresetConfig> configs,
) {
  return configs.firstWhere(
    (config) => config.id == id,
    orElse: () => configs.firstWhere(
      (config) => config.id == AppearancePresetIds.defaultSystem,
      orElse: () => configs.first,
    ),
  );
}

bool hasAppearancePresetConfig(
  String id,
  List<AppearancePresetConfig> configs,
) {
  return configs.any((config) => config.id == id);
}

String nextAppearancePresetId(
  String currentId,
  List<AppearancePresetConfig> configs,
) {
  if (configs.isEmpty) {
    return AppearancePresetIds.defaultSystem;
  }
  final index = configs.indexWhere((config) => config.id == currentId);
  return configs[(index + 1) % configs.length].id;
}

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
              ? AppearancePresetIds.tokyoNight
              : AppearancePresetIds.geekLightBlue),
      configs,
      platformBrightness,
    );
    return resolved.copyWith(selectedId: selected.id);
  }

  final baseId = selected.mode == AppearancePresetMode.dark
      ? AppearancePresetIds.tokyoNight
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

final _idPattern = RegExp(r'^[a-z0-9][a-z0-9-]{1,63}$');
final _hexColorPattern = RegExp(r'^#[0-9a-fA-F]{6}$');
final _tokenNamePattern = RegExp(r'^[a-z][a-z0-9-]*$');
final _allowedTokenValuePattern = RegExp(
  r'^(#[0-9a-fA-F]{6}|rgba\(\s*\d{1,3}\s*,\s*\d{1,3}\s*,\s*\d{1,3}\s*,\s*(?:0|1|0?\.\d+)\s*\)|var\(--[a-z0-9-]+\)|(?:-?\d+px\s+){2,4}rgba\(\s*\d{1,3}\s*,\s*\d{1,3}\s*,\s*\d{1,3}\s*,\s*(?:0|1|0?\.\d+)\s*\)(?:\s*,\s*(?:-?\d+px\s+){2,4}rgba\(\s*\d{1,3}\s*,\s*\d{1,3}\s*,\s*\d{1,3}\s*,\s*(?:0|1|0?\.\d+)\s*\))*)$',
);

const _requiredRuntimeTokens = [
  'bg-base',
  'bg-surface',
  'bg-subtle',
  'text-primary',
  'text-muted',
  'text-on-brand',
  'brand',
  'brand-strong',
  'brand-subtle',
  'success',
  'warning',
  'danger',
];

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
