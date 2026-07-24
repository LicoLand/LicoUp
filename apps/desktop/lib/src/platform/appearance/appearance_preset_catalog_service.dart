import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'package:licoup/src/contracts/appearance/appearance_preset_config.dart';
import 'package:licoup/src/platform/storage/portable_data_root.dart';

final class AppearancePresetCatalogLoadResult {
  const AppearancePresetCatalogLoadResult({
    required this.configs,
    required this.directory,
    this.errors = const <String>[],
  });

  final List<AppearancePresetConfig> configs;
  final Directory directory;
  final List<String> errors;
}

/// Loads appearance preset definitions only. Presentation preferences are
/// owned by the typed presentation-preferences repository.
final class AppearancePresetCatalogService {
  const AppearancePresetCatalogService({AssetBundle? assetBundle})
    : _assetBundle = assetBundle;

  static const String _presetsDirectoryName = 'appearance-presets';

  final AssetBundle? _assetBundle;

  Future<AppearancePresetCatalogLoadResult> loadCatalog(
    PortableDataRoot portableData,
  ) async {
    final directory = await presetsDirectory(portableData);
    await directory.create(recursive: true);

    final errors = <String>[];
    final loadedConfigs = <AppearancePresetConfig>[];
    final bundle = _assetBundle ?? rootBundle;

    for (
      var index = 0;
      index < builtInAppearancePresetAssetPaths.length;
      index++
    ) {
      final assetPath = builtInAppearancePresetAssetPaths[index];
      try {
        loadedConfigs.add(
          AppearancePresetConfig.fromJson(
            jsonDecode(await bundle.loadString(assetPath)),
          ),
        );
      } catch (_) {
        errors.add('built_in_preset_invalid:$index');
      }
    }

    final externalFiles = await directory
        .list()
        .where(
          (entity) => entity is File && p.extension(entity.path) == '.json',
        )
        .cast<File>()
        .toList();
    externalFiles.sort((left, right) => left.path.compareTo(right.path));

    for (var index = 0; index < externalFiles.length; index++) {
      try {
        loadedConfigs.add(
          AppearancePresetConfig.fromJson(
            jsonDecode(await externalFiles[index].readAsString()),
          ),
        );
      } catch (_) {
        errors.add('external_preset_invalid:$index');
      }
    }

    return AppearancePresetCatalogLoadResult(
      configs: mergeAppearancePresetConfigs(loadedConfigs),
      directory: directory,
      errors: List<String>.unmodifiable(errors),
    );
  }

  Future<Directory> presetsDirectory(PortableDataRoot portableData) async {
    final root = await portableData.clientDirectory();
    return Directory(p.join(root.path, _presetsDirectoryName));
  }
}
