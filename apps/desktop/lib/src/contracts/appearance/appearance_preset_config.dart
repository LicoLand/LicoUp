typedef AppearancePresetId = String;

const appearancePresetSchemaVersion =
    'v0.0.1:client-desktop:appearance-preset-2';

/// Schema versions this build still accepts from externally installed
/// presets. Older presets keep loading; roles introduced after they were
/// authored are filled in by the runtime derive layer rather than rejected.
const supportedAppearancePresetSchemaVersions = <String>{
  'v0.0.1:client-desktop:appearance-preset-1',
  appearancePresetSchemaVersion,
};

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

enum AppearanceBrightnessSelection { light, dark, system }

AppearanceBrightnessSelection appearanceBrightnessSelectionFor(
  String selectedId,
  List<AppearancePresetConfig> configs,
) {
  final selected = findAppearancePresetConfig(selectedId, configs);
  if (selected.mode == AppearancePresetMode.system) {
    return AppearanceBrightnessSelection.system;
  }
  return selected.mode == AppearancePresetMode.dark
      ? AppearanceBrightnessSelection.dark
      : AppearanceBrightnessSelection.light;
}

abstract final class AppearancePresetIds {
  static const defaultSystem = 'default-system';
  static const taroWaffle = 'lico-taro-waffle';
  static const starlitGold = 'lico-starlit-gold';

  static const builtIn = [defaultSystem, taroWaffle, starlitGold];

  /// Built-ins that exist only as resolution bases for system-following
  /// presets. They stay fully resolvable but are never offered as picker
  /// choices.
  ///
  /// Empty by design: both fixed presets are first-class choices. Taro
  /// Waffle carries the light-mode taro-violet identity and Starlit Gold
  /// the dark-mode sparkling-gold identity.
  static const resolutionOnly = <String>{};
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
  'assets/appearance-presets/lico-taro-waffle.json',
  'assets/appearance-presets/lico-starlit-gold.json',
];

/// Built-in theme styles. Runtime appearance is a token projection;
/// layouts and functional bindings are independent owners. Taro Waffle is
/// the light-mode taro-violet identity and Starlit Gold the dark-mode
/// sparkling-gold identity; the system default resolves between them by
/// platform brightness.
const builtInAppearancePresetConfigs = [
  AppearancePresetConfig(
    schemaVersion: appearancePresetSchemaVersion,
    id: 'default-system',
    label: {'en': 'System Default', 'zh-CN': '跟随系统'},
    mode: AppearancePresetMode.system,
    lightPresetId: 'lico-taro-waffle',
    darkPresetId: 'lico-starlit-gold',
  ),
  AppearancePresetConfig(
    schemaVersion: appearancePresetSchemaVersion,
    id: 'lico-taro-waffle',
    label: {'en': 'Taro Waffle · Light', 'zh-CN': '香芋华夫 · 浅色'},
    mode: AppearancePresetMode.light,
    tokens: {
      'bg-inset': '#f2e9da',
      'bg-base': '#f8f3eb',
      'bg-surface': '#fffdf9',
      'bg-subtle': '#f7efe3',
      'bg-raised': '#ffffff',
      'border-subtle': '#ece0cf',
      'border-strong': '#c6b093',
      'text-primary': '#3b2a1f',
      'text-secondary': '#654f3f',
      'text-muted': '#7d6654',
      'text-disabled': '#bba894',
      'brand': '#7b5cc9',
      'brand-strong': '#6346b4',
      'brand-subtle': '#efe7fc',
      'brand-border': '#c4b6e4',
      'text-on-brand': '#ffffff',
      'accent': '#9a5f2c',
      'accent-strong': '#7e4b20',
      'accent-surface': '#f7e8d4',
      'accent-border': '#e4c79f',
      'text-on-accent': '#ffffff',
      'success': '#278355',
      'warning': '#a26702',
      'danger': '#c2484b',
      'hover-overlay': 'rgba(59, 42, 31, 0.05)',
      'pressed-overlay': 'rgba(59, 42, 31, 0.09)',
      'selected-surface': '#ece2fb',
      'brand-glow': 'rgba(123, 92, 201, 0.20)',
      'accent-glow': 'rgba(196, 140, 80, 0.22)',
      'skeleton-base': '#f2e9da',
      'skeleton-highlight': '#fbf8f2',
      'font-family': 'geist',
      'icon-style': 'rounded',
      'motion-scale': '1',
      'surface-opacity': '1',
      'component-finish': 'crisp',
      'ambient-effect': 'waffle',
    },
  ),
  AppearancePresetConfig(
    schemaVersion: appearancePresetSchemaVersion,
    id: 'lico-starlit-gold',
    label: {'en': 'Starlit Gold · Dark', 'zh-CN': '星河鎏金 · 深色'},
    mode: AppearancePresetMode.dark,
    tokens: {
      'bg-inset': '#020104',
      'bg-base': '#0d0c10',
      'bg-surface': '#151418',
      'bg-subtle': '#1c1b1f',
      'bg-raised': '#232226',
      'border-subtle': '#2a292e',
      'border-strong': '#49484e',
      'text-primary': '#f5f4f8',
      'text-secondary': '#c8c6d0',
      'text-muted': '#8d8b97',
      'text-disabled': '#5a5963',
      'brand': '#e9bc4c',
      'brand-strong': '#f7d57e',
      'brand-subtle': '#221c0e',
      'brand-border': '#7a5e1f',
      'text-on-brand': '#1f1604',
      'accent': '#b8a4ff',
      'accent-strong': '#d6caff',
      'accent-surface': '#1c1830',
      'accent-border': '#4b3f86',
      'text-on-accent': '#140b30',
      'success': '#3dd69b',
      'warning': '#f5c451',
      'danger': '#ff7a8a',
      'hover-overlay': 'rgba(255, 255, 255, 0.05)',
      'pressed-overlay': 'rgba(255, 255, 255, 0.09)',
      'selected-surface': '#1d1b27',
      'brand-glow': 'rgba(233, 188, 76, 0.28)',
      'accent-glow': 'rgba(184, 164, 255, 0.30)',
      'skeleton-base': '#1c1b1f',
      'skeleton-highlight': '#252429',
      'font-family': 'geist',
      'icon-style': 'rounded',
      'motion-scale': '1',
      'surface-opacity': '0.85',
      'component-finish': 'glass',
      'ambient-effect': 'starfield',
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
  // `1` and `2` are accepted as integer shorthands for the matching string
  // schema version so hand-authored presets stay terse.
  final schemaVersion = switch (rawSchemaVersion) {
    1 => 'v0.0.1:client-desktop:appearance-preset-1',
    2 => appearancePresetSchemaVersion,
    _ => rawSchemaVersion,
  };
  if (!supportedAppearancePresetSchemaVersions.contains(schemaVersion)) {
    errors.add(
      'schemaVersion must be one of '
      '${supportedAppearancePresetSchemaVersions.join(', ')}',
    );
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
            !_validAppearanceTokenValue(key, tokenValue)) {
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
      // Roles introduced by appearance-preset-2. A v1 preset omits them and
      // the runtime derive layer fills them in; a preset that declares v2
      // must supply them so it cannot silently inherit another palette's
      // brand or interaction color.
      if (schemaVersion == appearancePresetSchemaVersion) {
        for (final token in _requiredSchemaTwoTokens) {
          if (!_hexColorPattern.hasMatch(tokens[token] ?? '')) {
            errors.add('tokens.$token must be a 6-digit hex color');
          }
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

/// Roles a preset declaring `appearance-preset-2` must supply itself.
const _requiredSchemaTwoTokens = [
  'bg-inset',
  'bg-raised',
  'border-subtle',
  'border-strong',
  'text-secondary',
  'text-disabled',
  'brand-border',
  'accent',
  'accent-strong',
  'accent-surface',
  'accent-border',
  'text-on-accent',
];

/// Visual-only tokens deliberately have no dimensions, ordering, destinations,
/// callbacks or runtime authority. Unknown CSS tokens retain existing parsing.
bool _validAppearanceTokenValue(String key, String value) => switch (key) {
  'font-family' => const {'geist', 'system'}.contains(value),
  'icon-style' => const {'outlined', 'rounded'}.contains(value),
  'motion-scale' => const {'0.75', '1', '1.25'}.contains(value),
  'surface-opacity' => const {'0.85', '0.9', '0.95', '1'}.contains(value),
  'component-finish' => const {'crisp', 'glass'}.contains(value),
  'composer-activity-effect' => const {'breathing', 'pulse'}.contains(value),
  'ambient-effect' => const {'none', 'starfield', 'waffle'}.contains(value),
  _ => _allowedTokenValuePattern.hasMatch(value),
};
