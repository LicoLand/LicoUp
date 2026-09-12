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
  static const licoSoda = 'lico-soda';
  static const licoSodaLight = 'lico-soda-light';

  static const builtIn = [defaultSystem, licoSoda, licoSodaLight];

  /// Built-ins that exist only as resolution bases for system-following
  /// presets. They stay fully resolvable but are never offered as picker
  /// choices.
  ///
  /// Empty by design: both fixed presets share one brand identity, so each is
  /// a legitimate direct choice. Selecting light mode must never change the
  /// brand color.
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
  'assets/appearance-presets/lico-soda.json',
  'assets/appearance-presets/lico-soda-light.json',
];

/// Built-in Orbital theme styles. Runtime appearance is a token projection;
/// layouts and functional bindings are independent owners.
const builtInAppearancePresetConfigs = [
  AppearancePresetConfig(
    schemaVersion: appearancePresetSchemaVersion,
    id: 'default-system',
    label: {'en': 'System Default', 'zh-CN': '跟随系统'},
    mode: AppearancePresetMode.system,
    lightPresetId: 'lico-soda-light',
    darkPresetId: 'lico-soda',
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
      'bg-inset': '#dddde2',
      'bg-base': '#eaebee',
      'bg-surface': '#ffffff',
      'bg-subtle': '#f5f6f9',
      'bg-raised': '#ffffff',
      'border-subtle': '#d1d2d8',
      'border-strong': '#a6a7ae',
      'text-primary': '#1a1a20',
      'text-secondary': '#4f4f55',
      'text-muted': '#68696f',
      'text-disabled': '#9d9ea3',
      'brand': '#d9e320',
      'brand-strong': '#878e1f',
      'brand-subtle': '#f5f8c5',
      'brand-border': '#bfc744',
      'text-on-brand': '#1b1d00',
      'accent': '#4f596a',
      'accent-strong': '#303a4b',
      'accent-surface': '#e9ebef',
      'accent-border': '#9aa2af',
      'text-on-accent': '#ffffff',
      'success': '#158351',
      'warning': '#9c660c',
      'danger': '#ce1828',
      'hover-overlay': 'rgba(26, 26, 32, 0.05)',
      'pressed-overlay': 'rgba(26, 26, 32, 0.09)',
      'selected-surface': '#eeeef1',
      'brand-glow': 'rgba(217, 227, 32, 0.30)',
      'accent-glow': 'rgba(79, 89, 106, 0.15)',
      'skeleton-base': '#eeeef1',
      'skeleton-highlight': '#ffffff',
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
  _ => _allowedTokenValuePattern.hasMatch(value),
};
