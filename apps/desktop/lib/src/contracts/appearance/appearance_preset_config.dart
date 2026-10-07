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
  static const licoMist = 'lico-mist';
  static const licoMistLight = 'lico-mist-light';
  static const licoCream = 'lico-cream';
  static const licoCreamLight = 'lico-cream-light';
  static const licoRoyale = 'lico-royale';
  static const licoRoyaleLight = 'lico-royale-light';
  static const licoSoda = 'lico-soda';
  static const licoSodaLight = 'lico-soda-light';

  static const builtIn = [
    defaultSystem,
    licoMist,
    licoMistLight,
    licoCream,
    licoCreamLight,
    licoRoyale,
    licoRoyaleLight,
    licoSoda,
    licoSodaLight,
  ];

  /// Built-ins that exist only as resolution bases for system-following
  /// presets. They stay fully resolvable but are never offered as picker
  /// choices.
  ///
  /// Empty by design: all fixed presets are first-class choices. The taro,
  /// cream and royale pairs carry the violet-and-gold identity; the soda
  /// pair preserves the earlier Orbital lemon identity.
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
  'assets/appearance-presets/lico-mist.json',
  'assets/appearance-presets/lico-mist-light.json',
  'assets/appearance-presets/lico-cream.json',
  'assets/appearance-presets/lico-cream-light.json',
  'assets/appearance-presets/lico-royale.json',
  'assets/appearance-presets/lico-royale-light.json',
  'assets/appearance-presets/lico-soda.json',
  'assets/appearance-presets/lico-soda-light.json',
];

/// Built-in theme styles. Runtime appearance is a token projection;
/// layouts and functional bindings are independent owners. The mist, cream
/// and royale pairs carry the taro/violet-and-gold identity; the soda pair
/// preserves the earlier Orbital lemon identity.
const builtInAppearancePresetConfigs = [
  AppearancePresetConfig(
    schemaVersion: appearancePresetSchemaVersion,
    id: 'default-system',
    label: {'en': 'System Default', 'zh-CN': '跟随系统'},
    mode: AppearancePresetMode.system,
    lightPresetId: 'lico-mist-light',
    darkPresetId: 'lico-mist',
  ),
  AppearancePresetConfig(
    schemaVersion: appearancePresetSchemaVersion,
    id: 'lico-mist',
    label: {'en': 'Taro Mist · Dark', 'zh-CN': '香芋晨雾 · 深色'},
    mode: AppearancePresetMode.dark,
    tokens: {
      'bg-inset': '#070409',
      'bg-base': '#130c22',
      'bg-surface': '#1c1330',
      'bg-subtle': '#241841',
      'bg-raised': '#2d1f4e',
      'border-subtle': '#35255a',
      'border-strong': '#55407f',
      'text-primary': '#f2eefc',
      'text-secondary': '#cdc4e8',
      'text-muted': '#a294c9',
      'text-disabled': '#6f5f96',
      'brand': '#d6a43c',
      'brand-strong': '#f2d38b',
      'brand-subtle': '#343020',
      'brand-border': '#8a6114',
      'text-on-brand': '#241a02',
      'accent': '#a78bfa',
      'accent-strong': '#c4b5fd',
      'accent-surface': '#2a1d4d',
      'accent-border': '#5b4594',
      'text-on-accent': '#160b2e',
      'success': '#34d399',
      'warning': '#fbbf24',
      'danger': '#fb7185',
      'hover-overlay': 'rgba(242, 238, 252, 0.06)',
      'pressed-overlay': 'rgba(242, 238, 252, 0.11)',
      'selected-surface': '#2e2054',
      'brand-glow': 'rgba(214, 164, 60, 0.25)',
      'accent-glow': 'rgba(167, 139, 250, 0.22)',
      'skeleton-base': '#241841',
      'skeleton-highlight': '#2f2252',
      'font-family': 'geist',
      'icon-style': 'rounded',
      'motion-scale': '1',
      'surface-opacity': '1',
      'component-finish': 'crisp',
    },
  ),
  AppearancePresetConfig(
    schemaVersion: appearancePresetSchemaVersion,
    id: 'lico-mist-light',
    label: {'en': 'Taro Mist · Light', 'zh-CN': '香芋晨雾 · 浅色'},
    mode: AppearancePresetMode.light,
    tokens: {
      'bg-inset': '#ece7e1',
      'bg-base': '#f7f4ef',
      'bg-surface': '#ffffff',
      'bg-subtle': '#f8f6f3',
      'bg-raised': '#ffffff',
      'border-subtle': '#e7e0d7',
      'border-strong': '#b8ae9f',
      'text-primary': '#15120f',
      'text-secondary': '#4a453f',
      'text-muted': '#736d66',
      'text-disabled': '#b3aca2',
      'brand': '#6a4ce0',
      'brand-strong': '#4f36c4',
      'brand-subtle': '#f1edff',
      'brand-border': '#c0b2f2',
      'text-on-brand': '#ffffff',
      'accent': '#8a6114',
      'accent-strong': '#6d4a0e',
      'accent-surface': '#fbf3df',
      'accent-border': '#ead9a8',
      'text-on-accent': '#ffffff',
      'success': '#0e7a4d',
      'warning': '#9a6a0a',
      'danger': '#c43d3d',
      'hover-overlay': 'rgba(21, 18, 15, 0.05)',
      'pressed-overlay': 'rgba(21, 18, 15, 0.09)',
      'selected-surface': '#ebe4fc',
      'brand-glow': 'rgba(106, 76, 224, 0.18)',
      'accent-glow': 'rgba(214, 164, 60, 0.22)',
      'skeleton-base': '#efece7',
      'skeleton-highlight': '#f8f6f2',
      'font-family': 'geist',
      'icon-style': 'rounded',
      'motion-scale': '1',
      'surface-opacity': '1',
      'component-finish': 'crisp',
    },
  ),
  AppearancePresetConfig(
    schemaVersion: appearancePresetSchemaVersion,
    id: 'lico-cream',
    label: {'en': 'Butter Cream · Dark', 'zh-CN': '奶油主场 · 深色'},
    mode: AppearancePresetMode.dark,
    tokens: {
      'bg-inset': '#060409',
      'bg-base': '#120d1c',
      'bg-surface': '#1a1426',
      'bg-subtle': '#221a33',
      'bg-raised': '#2b2140',
      'border-subtle': '#332747',
      'border-strong': '#5a4678',
      'text-primary': '#efeaf8',
      'text-secondary': '#c9c0dd',
      'text-muted': '#9e92bd',
      'text-disabled': '#6a5f86',
      'brand': '#c9973a',
      'brand-strong': '#e8c47c',
      'brand-subtle': '#343020',
      'brand-border': '#7c5f22',
      'text-on-brand': '#221703',
      'accent': '#9d8bf0',
      'accent-strong': '#bfadf7',
      'accent-surface': '#271c47',
      'accent-border': '#524083',
      'text-on-accent': '#150d2b',
      'success': '#34d399',
      'warning': '#fbbf24',
      'danger': '#fb7185',
      'hover-overlay': 'rgba(239, 234, 248, 0.06)',
      'pressed-overlay': 'rgba(239, 234, 248, 0.11)',
      'selected-surface': '#28203d',
      'brand-glow': 'rgba(201, 151, 58, 0.24)',
      'accent-glow': 'rgba(157, 139, 240, 0.20)',
      'skeleton-base': '#221a33',
      'skeleton-highlight': '#2d2244',
      'font-family': 'geist',
      'icon-style': 'rounded',
      'motion-scale': '1',
      'surface-opacity': '1',
      'component-finish': 'crisp',
    },
  ),
  AppearancePresetConfig(
    schemaVersion: appearancePresetSchemaVersion,
    id: 'lico-cream-light',
    label: {'en': 'Butter Cream · Light', 'zh-CN': '奶油主场 · 浅色'},
    mode: AppearancePresetMode.light,
    tokens: {
      'bg-inset': '#ecdcce',
      'bg-base': '#f7eee4',
      'bg-surface': '#fdf9f2',
      'bg-subtle': '#f5ead9',
      'bg-raised': '#fffaf3',
      'border-subtle': '#e9d8c6',
      'border-strong': '#c3a684',
      'text-primary': '#472413',
      'text-secondary': '#6b4a33',
      'text-muted': '#7a5c45',
      'text-disabled': '#c0a68f',
      'brand': '#7c5ce8',
      'brand-strong': '#5f3fd6',
      'brand-subtle': '#f1edff',
      'brand-border': '#c0b2f2',
      'text-on-brand': '#ffffff',
      'accent': '#8a6114',
      'accent-strong': '#6d4a0e',
      'accent-surface': '#fbf3df',
      'accent-border': '#ead9a8',
      'text-on-accent': '#ffffff',
      'success': '#0e7a4d',
      'warning': '#9a6a0a',
      'danger': '#c0452e',
      'hover-overlay': 'rgba(71, 36, 19, 0.05)',
      'pressed-overlay': 'rgba(71, 36, 19, 0.09)',
      'selected-surface': '#f3e5d4',
      'brand-glow': 'rgba(124, 92, 232, 0.18)',
      'accent-glow': 'rgba(214, 164, 60, 0.20)',
      'skeleton-base': '#f0e2d2',
      'skeleton-highlight': '#faf1e4',
      'font-family': 'geist',
      'icon-style': 'rounded',
      'motion-scale': '1',
      'surface-opacity': '1',
      'component-finish': 'crisp',
    },
  ),
  AppearancePresetConfig(
    schemaVersion: appearancePresetSchemaVersion,
    id: 'lico-royale',
    label: {'en': 'Violet Royale · Dark', 'zh-CN': '紫雾浓郁 · 深色'},
    mode: AppearancePresetMode.dark,
    tokens: {
      'bg-inset': '#0a0518',
      'bg-base': '#160d2e',
      'bg-surface': '#241446',
      'bg-subtle': '#2f1c55',
      'bg-raised': '#3a2468',
      'border-subtle': '#41296f',
      'border-strong': '#60459c',
      'text-primary': '#f5f0ff',
      'text-secondary': '#d3c9f2',
      'text-muted': '#ab9ed8',
      'text-disabled': '#7666a6',
      'brand': '#d6a43c',
      'brand-strong': '#f2d38b',
      'brand-subtle': '#343020',
      'brand-border': '#8a6114',
      'text-on-brand': '#241a02',
      'accent': '#b7a3f5',
      'accent-strong': '#d4c8fa',
      'accent-surface': '#30206b',
      'accent-border': '#6a4fc0',
      'text-on-accent': '#190c36',
      'success': '#34d399',
      'warning': '#fbbf24',
      'danger': '#fb7185',
      'hover-overlay': 'rgba(245, 240, 255, 0.07)',
      'pressed-overlay': 'rgba(245, 240, 255, 0.12)',
      'selected-surface': '#352466',
      'brand-glow': 'rgba(214, 164, 60, 0.28)',
      'accent-glow': 'rgba(183, 163, 245, 0.24)',
      'skeleton-base': '#2f1c55',
      'skeleton-highlight': '#3c2668',
      'font-family': 'geist',
      'icon-style': 'rounded',
      'motion-scale': '1',
      'surface-opacity': '1',
      'component-finish': 'crisp',
    },
  ),
  AppearancePresetConfig(
    schemaVersion: appearancePresetSchemaVersion,
    id: 'lico-royale-light',
    label: {'en': 'Violet Royale · Light', 'zh-CN': '紫雾浓郁 · 浅色'},
    mode: AppearancePresetMode.light,
    tokens: {
      'bg-inset': '#e4dcf8',
      'bg-base': '#f6f3ff',
      'bg-surface': '#ffffff',
      'bg-subtle': '#efe9ff',
      'bg-raised': '#ffffff',
      'border-subtle': '#ddd3f2',
      'border-strong': '#b8a6e8',
      'text-primary': '#1b1340',
      'text-secondary': '#443a6e',
      'text-muted': '#6a5f96',
      'text-disabled': '#a89ecb',
      'brand': '#4f36c4',
      'brand-strong': '#3b249e',
      'brand-subtle': '#ebe5ff',
      'brand-border': '#bdaaf0',
      'text-on-brand': '#ffffff',
      'accent': '#8a6114',
      'accent-strong': '#6d4a0e',
      'accent-surface': '#fbf3df',
      'accent-border': '#ead9a8',
      'text-on-accent': '#ffffff',
      'success': '#0e7a4d',
      'warning': '#9a6a0a',
      'danger': '#c43d3d',
      'hover-overlay': 'rgba(27, 19, 64, 0.05)',
      'pressed-overlay': 'rgba(27, 19, 64, 0.09)',
      'selected-surface': '#e2d9fb',
      'brand-glow': 'rgba(79, 54, 196, 0.20)',
      'accent-glow': 'rgba(214, 164, 60, 0.20)',
      'skeleton-base': '#eae4fb',
      'skeleton-highlight': '#f5f1ff',
      'font-family': 'geist',
      'icon-style': 'rounded',
      'motion-scale': '1',
      'surface-opacity': '1',
      'component-finish': 'crisp',
    },
  ),
  AppearancePresetConfig(
    schemaVersion: appearancePresetSchemaVersion,
    id: 'lico-soda',
    label: {'en': 'Orbital · Dark', 'zh-CN': '轨道 · 深色'},
    mode: AppearancePresetMode.dark,
    tokens: {
      'bg-inset': '#030304',
      'bg-base': '#0e0f11',
      'bg-surface': '#1b1c1f',
      'bg-subtle': '#292a2e',
      'bg-raised': '#393a3f',
      'border-subtle': '#37383d',
      'border-strong': '#5c5d64',
      'text-primary': '#f4f5f7',
      'text-secondary': '#ced0d5',
      'text-muted': '#acadb3',
      'text-disabled': '#73747c',
      'brand': '#e7f22e',
      'brand-strong': '#f0fc51',
      'brand-subtle': '#2e2f21',
      'brand-border': '#878d24',
      'text-on-brand': '#171800',
      'accent': '#cbd0d9',
      'accent-strong': '#f1f4f9',
      'accent-surface': '#282b31',
      'accent-border': '#7e8490',
      'text-on-accent': '#121419',
      'success': '#2be18e',
      'warning': '#feae36',
      'danger': '#fb5f5b',
      'hover-overlay': 'rgba(244, 244, 247, 0.07)',
      'pressed-overlay': 'rgba(244, 244, 247, 0.12)',
      'selected-surface': '#2a2a2f',
      'brand-glow': 'rgba(231, 242, 46, 0.18)',
      'accent-glow': 'rgba(203, 208, 217, 0.18)',
      'skeleton-base': '#2a2a2f',
      'skeleton-highlight': '#3a3a3f',
      'font-family': 'geist',
      'icon-style': 'outlined',
      'motion-scale': '1',
      'surface-opacity': '1',
      'component-finish': 'crisp',
    },
  ),
  AppearancePresetConfig(
    schemaVersion: appearancePresetSchemaVersion,
    id: 'lico-soda-light',
    label: {'en': 'Orbital · Light', 'zh-CN': '轨道 · 浅色'},
    mode: AppearancePresetMode.light,
    tokens: {
      'bg-inset': '#e8d2c5',
      'bg-base': '#f4e3dc',
      'bg-surface': '#fcf3ea',
      'bg-subtle': '#f7e7dc',
      'bg-raised': '#fef8f2',
      'border-subtle': '#e4cdbe',
      'border-strong': '#c7a28c',
      'text-primary': '#472413',
      'text-secondary': '#6b3f27',
      'text-muted': '#7c5340',
      'text-disabled': '#bca08e',
      'brand': '#c94535',
      'brand-strong': '#b23e34',
      'brand-subtle': '#f9dcd4',
      'brand-border': '#e68b7c',
      'text-on-brand': '#ffffff',
      'accent': '#1b628b',
      'accent-strong': '#185a82',
      'accent-surface': '#daeef6',
      'accent-border': '#8ccbe9',
      'text-on-accent': '#ffffff',
      'success': '#0b6b44',
      'warning': '#7e5406',
      'danger': '#b52b22',
      'hover-overlay': 'rgba(71, 36, 19, 0.05)',
      'pressed-overlay': 'rgba(71, 36, 19, 0.09)',
      'selected-surface': '#f5e2d6',
      'brand-glow': 'rgba(201, 69, 53, 0.22)',
      'accent-glow': 'rgba(27, 98, 139, 0.16)',
      'skeleton-base': '#efdfd4',
      'skeleton-highlight': '#fbf2ea',
      'font-family': 'geist',
      'icon-style': 'outlined',
      'motion-scale': '1',
      'surface-opacity': '1',
      'component-finish': 'crisp',
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
  _ => _allowedTokenValuePattern.hasMatch(value),
};
