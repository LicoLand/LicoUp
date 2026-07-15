class LocalRuntimePreferences {
  const LocalRuntimePreferences({
    required this.sourceRoot,
    required this.presetConfig,
    this.port = defaultPort,
  });

  static const currentSchemaVersion = 1;
  static const defaultPort = 17328;
  static const presetRelativePath =
      'packages/foundation/config/composition-presets/client-local-runtime.preset.json';

  final String sourceRoot;
  final String presetConfig;
  final int port;

  factory LocalRuntimePreferences.defaults({
    String sourceRoot = '',
    String presetConfig = '',
  }) {
    return LocalRuntimePreferences(
      sourceRoot: sourceRoot,
      presetConfig: presetConfig,
    ).normalized();
  }

  factory LocalRuntimePreferences.fromJson(Map<String, dynamic> json) {
    return LocalRuntimePreferences(
      sourceRoot: (json['sourceRoot'] ?? '').toString(),
      presetConfig: (json['presetConfig'] ?? '').toString(),
      port: _normalizePort(json['port']),
    );
  }

  LocalRuntimePreferences copyWith({
    String? sourceRoot,
    String? presetConfig,
    int? port,
  }) {
    return LocalRuntimePreferences(
      sourceRoot: sourceRoot ?? this.sourceRoot,
      presetConfig: presetConfig ?? this.presetConfig,
      port: port ?? this.port,
    );
  }

  LocalRuntimePreferences normalized({
    String Function(String sourceRoot)? presetConfigForSourceRoot,
  }) {
    final normalizedSourceRoot = sourceRoot.trim();
    final normalizedPresetConfig = presetConfig.trim().isNotEmpty
        ? presetConfig.trim()
        : _presetConfigForSourceRoot(
            normalizedSourceRoot,
            presetConfigForSourceRoot,
          );
    return LocalRuntimePreferences(
      sourceRoot: normalizedSourceRoot,
      presetConfig: normalizedPresetConfig,
      port: _normalizePort(port),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'schemaVersion': currentSchemaVersion,
      'sourceRoot': sourceRoot,
      'presetConfig': presetConfig,
      'port': port,
    };
  }

  static String defaultPresetConfigForSourceRoot(String sourceRoot) {
    final trimmed = sourceRoot.trim();
    if (trimmed.isEmpty) {
      return '';
    }
    final separator = trimmed.endsWith('/') || trimmed.endsWith('\\')
        ? ''
        : '/';
    return '$trimmed$separator$presetRelativePath';
  }

  static String _presetConfigForSourceRoot(
    String sourceRoot,
    String Function(String sourceRoot)? override,
  ) {
    if (sourceRoot.isEmpty) {
      return '';
    }
    return override?.call(sourceRoot) ??
        defaultPresetConfigForSourceRoot(sourceRoot);
  }

  static int _normalizePort(Object? value) {
    final number = value is num
        ? value.toInt()
        : int.tryParse((value ?? '').toString());
    if (number == null || number <= 0 || number > 65535) {
      return defaultPort;
    }
    return number;
  }
}

abstract class LocalRuntimePreferencesStore {
  const LocalRuntimePreferencesStore();

  Future<LocalRuntimePreferences> load(Object portableData);
  Future<void> save(Object portableData, LocalRuntimePreferences preferences);
}
