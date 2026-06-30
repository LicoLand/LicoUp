import 'dart:convert';
import 'dart:io';

import 'package:flutter_client/src/services/local_runtime_preferences_service.dart';
import 'package:flutter_client/src/services/portable_data_root.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('defaults to the built-in client runtime port', () async {
    final data = await Directory.systemTemp.createTemp('lico-runtime-data-');
    addTearDown(() => data.delete(recursive: true));

    const service = LocalRuntimePreferencesService();
    final preferences = await service.load(
      PortableDataRoot(dataDirectoryOverride: data),
    );

    expect(preferences.port, LocalRuntimePreferences.defaultPort);
  });

  test('saves and reloads local runtime port preferences', () async {
    final data = await Directory.systemTemp.createTemp('lico-runtime-prefs-');
    addTearDown(() => data.delete(recursive: true));
    final portableData = PortableDataRoot(dataDirectoryOverride: data);
    const service = LocalRuntimePreferencesService();

    await service.save(
      portableData,
      const LocalRuntimePreferences(port: 17329),
    );

    final loaded = await service.load(portableData);
    expect(loaded.port, 17329);

    final raw =
        jsonDecode(
              await File(
                p.join(
                  data.path,
                  'future-client',
                  'local-runtime-preferences.json',
                ),
              ).readAsString(),
            )
            as Map<String, dynamic>;
    expect(raw, {
      'schemaVersion': LocalRuntimePreferences.currentSchemaVersion,
      'port': 17329,
    });
  });

  test('normalizes invalid stored ports', () async {
    final data = await Directory.systemTemp.createTemp('lico-runtime-invalid-');
    addTearDown(() => data.delete(recursive: true));
    final portableData = PortableDataRoot(dataDirectoryOverride: data);
    const service = LocalRuntimePreferencesService();

    await service.save(portableData, const LocalRuntimePreferences(port: -1));

    final loaded = await service.load(portableData);
    expect(loaded.port, LocalRuntimePreferences.defaultPort);
  });
}
