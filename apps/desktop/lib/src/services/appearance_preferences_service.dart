import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../ui/appearance_preset_config.dart';
import 'portable_data_root.dart';

class AppearancePresetCatalogLoadResult {
  const AppearancePresetCatalogLoadResult({
    required this.configs,
    required this.directory,
    this.errors = const [],
  });

  final List<AppearancePresetConfig> configs;
  final Directory directory;
  final List<String> errors;
}

class AppearancePreferencesService {
  const AppearancePreferencesService({AssetBundle? assetBundle})
    : _assetBundle = assetBundle;

  static const _fileName = 'appearance-preferences.json';
  static const _presetsDirectoryName = 'appearance-presets';

  final AssetBundle? _assetBundle;

  Future<AppearancePresetCatalogLoadResult> loadCatalog(
    PortableDataRoot portableData,
  ) async {
    final directory = await presetsDirectory(portableData);
    await directory.create(recursive: true);

    final errors = <String>[];
    final loadedConfigs = <AppearancePresetConfig>[];
    final bundle = _assetBundle ?? rootBundle;

    for (final assetPath in builtInAppearancePresetAssetPaths) {
      try {
        loadedConfigs.add(
          AppearancePresetConfig.fromJson(
            jsonDecode(await bundle.loadString(assetPath)),
          ),
        );
      } catch (error) {
        errors.add('$assetPath: $error');
      }
    }

    final externalFiles = await directory
        .list()
        .where(
          (entity) => entity is File && p.extension(entity.path) == '.json',
        )
        .cast<File>()
        .toList();
    externalFiles.sort((a, b) => a.path.compareTo(b.path));

    for (final file in externalFiles) {
      try {
        loadedConfigs.add(
          AppearancePresetConfig.fromJson(
            jsonDecode(await file.readAsString()),
          ),
        );
      } catch (error) {
        errors.add('${file.path}: $error');
      }
    }

    return AppearancePresetCatalogLoadResult(
      configs: mergeAppearancePresetConfigs(loadedConfigs),
      directory: directory,
      errors: List.unmodifiable(errors),
    );
  }

  Future<String> loadSelectedPresetId(
    PortableDataRoot portableData,
    List<AppearancePresetConfig> configs,
  ) async {
    final file = await _preferencesFile(portableData);
    if (!await file.exists()) {
      return AppearancePresetIds.defaultSystem;
    }

    try {
      final json = jsonDecode(await file.readAsString());
      if (json is Map<String, dynamic>) {
        final presetId = (json['appearancePresetId'] ?? '').toString();
        if (hasAppearancePresetConfig(presetId, configs)) {
          return presetId;
        }
      }
    } catch (_) {
      return AppearancePresetIds.defaultSystem;
    }
    return AppearancePresetIds.defaultSystem;
  }

  Future<void> save(PortableDataRoot portableData, String presetId) async {
    await _writePreferences(portableData, {
      'schemaVersion': 1,
      'appearancePresetId': presetId,
    });
  }

  Future<void> _writePreferences(
    PortableDataRoot portableData,
    Map<String, Object?> payload,
  ) async {
    final file = await _preferencesFile(portableData);
    await file.parent.create(recursive: true);
    final temp = File(
      p.join(
        file.parent.path,
        '.${p.basename(file.path)}.${DateTime.now().toUtc().microsecondsSinceEpoch}.tmp',
      ),
    );
    await temp.writeAsString(
      const JsonEncoder.withIndent('  ').convert(payload),
      flush: true,
    );
    await temp.rename(file.path);
  }

  Future<Directory> presetsDirectory(PortableDataRoot portableData) async {
    final root = await portableData.futureClientDirectory();
    return Directory(p.join(root.path, _presetsDirectoryName));
  }

  Future<File> _preferencesFile(PortableDataRoot portableData) async {
    final root = await portableData.futureClientDirectory();
    return File(p.join(root.path, _fileName));
  }
}
