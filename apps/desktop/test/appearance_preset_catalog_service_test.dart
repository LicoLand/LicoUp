import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_client/src/contracts/appearance/appearance_preset_config.dart';
import 'package:flutter_client/src/platform/appearance/appearance_preset_catalog_service.dart';
import 'package:flutter_client/src/platform/storage/portable_data_root.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'loads only preset catalogs and returns bounded validation errors',
    () async {
      final rootDirectory = await Directory.systemTemp.createTemp(
        'appearance-preset-catalog-',
      );
      addTearDown(() async {
        if (await rootDirectory.exists()) {
          await rootDirectory.delete(recursive: true);
        }
      });
      final portableData = PortableDataRoot(
        dataDirectoryOverride: rootDirectory,
      );
      final assetBundle = _MemoryAssetBundle({
        for (
          var index = 0;
          index < builtInAppearancePresetAssetPaths.length;
          index++
        )
          builtInAppearancePresetAssetPaths[index]: jsonEncode(
            _configJson(builtInAppearancePresetConfigs[index]),
          ),
      });
      final service = AppearancePresetCatalogService(assetBundle: assetBundle);
      final presetsDirectory = await service.presetsDirectory(portableData);
      await presetsDirectory.create(recursive: true);
      final customConfig = _configJson(
        builtInAppearancePresetConfigs[1],
        id: 'custom-preset',
        label: const {'en': 'Custom Preset', 'zh-CN': '自定义方案'},
      );
      await File(
        '${presetsDirectory.path}/a-custom.json',
      ).writeAsString(jsonEncode(customConfig));
      await File('${presetsDirectory.path}/b-invalid.json').writeAsString('{}');

      final result = await service.loadCatalog(portableData);

      expect(
        result.configs.any((config) => config.id == 'custom-preset'),
        isTrue,
      );
      expect(
        result.configs,
        hasLength(builtInAppearancePresetConfigs.length + 1),
      );
      expect(result.errors, const ['external_preset_invalid:1']);
    },
  );
}

Map<String, Object?> _configJson(
  AppearancePresetConfig config, {
  String? id,
  Map<String, String>? label,
}) => <String, Object?>{
  'schemaVersion': config.schemaVersion,
  'id': id ?? config.id,
  'label': label ?? config.label,
  'mode': config.mode.id,
  'lightPresetId': ?config.lightPresetId,
  'darkPresetId': ?config.darkPresetId,
  if (config.tokens.isNotEmpty) 'tokens': config.tokens,
};

final class _MemoryAssetBundle extends CachingAssetBundle {
  _MemoryAssetBundle(this.assets);

  final Map<String, String> assets;

  @override
  Future<ByteData> load(String key) async {
    final value = assets[key];
    if (value == null) {
      throw StateError('asset_not_found');
    }
    return ByteData.sublistView(Uint8List.fromList(utf8.encode(value)));
  }
}
