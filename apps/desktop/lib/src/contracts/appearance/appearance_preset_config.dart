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
  static const licoCrystal = 'lico-crystal';
  static const geekLightBlue = 'geek-light-blue';
  static const sunsetEmber = 'sunset-ember';
  static const tokyoNight = 'tokyo-night';
  static const monokai = 'monokai';
  static const cyberpunk = 'cyberpunk';
  static const cappuccinoDark = 'cappuccino-dark';

  static const builtIn = [
    defaultSystem,
    licoCrystal,
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
  'assets/appearance-presets/lico-crystal.json',
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
    darkPresetId: AppearancePresetIds.licoCrystal,
  ),
  AppearancePresetConfig(
    schemaVersion: appearancePresetSchemaVersion,
    id: AppearancePresetIds.licoCrystal,
    label: {'en': 'Lico Crystal', 'zh-CN': '黑晶灿金'},
    mode: AppearancePresetMode.dark,
    tokens: {
      'bg-base': '#070707',
      'bg-surface': '#0d0d0d',
      'bg-subtle': '#151515',
      'bg-inset': '#020202',
      'border-subtle': '#242424',
      'border-strong': '#3a3a3a',
      'text-primary': '#ededed',
      'text-secondary': '#c8c8c8',
      'text-muted': '#969696',
      'text-disabled': '#5c5c5c',
      'text-on-brand': '#171300',
      'brand': '#fef100',
      'brand-strong': '#fff75c',
      'brand-subtle': '#2e2909',
      'brand-muted': '#6b6117',
      'info': '#5ed7f2',
      'info-surface': '#062029',
      'info-border': '#155c70',
      'success': '#3ddc97',
      'success-surface': '#052a1c',
      'success-border': '#0e6b44',
      'warning': '#ff9e2c',
      'warning-text': '#ffc98a',
      'warning-surface': '#2a1a04',
      'warning-border': '#7a4a06',
      'danger': '#ff5a4e',
      'danger-surface': '#2b0e0a',
      'danger-border': '#7a211a',
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
