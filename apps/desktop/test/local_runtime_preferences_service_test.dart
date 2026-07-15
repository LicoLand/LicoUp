import 'dart:convert';
import 'dart:io';

import 'package:flutter_client/src/contracts/local_runtime_preferences.dart';
import 'package:flutter_client/src/platform/local_runtime/local_runtime_preferences_store.dart';
import 'package:flutter_client/src/platform/storage/portable_data_root.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('normalizes reusable local runtime preference model values', () {
    final preferences = const LocalRuntimePreferences(
      sourceRoot: ' /repo ',
      presetConfig: ' ',
      port: -1,
    ).normalized();

    expect(preferences.sourceRoot, '/repo');
    expect(
      preferences.presetConfig,
      '/repo/${LocalRuntimePreferences.presetRelativePath}',
    );
    expect(preferences.port, LocalRuntimePreferences.defaultPort);
  });

  test('discovers source root and derives preset config', () async {
    final repo = await Directory.systemTemp.createTemp('lico-runtime-repo-');
    final data = await Directory.systemTemp.createTemp('lico-runtime-data-');
    addTearDown(() => repo.delete(recursive: true));
    addTearDown(() => data.delete(recursive: true));
    final presetFile = File(
      p.join(
        repo.path,
        'packages',
        'foundation',
        'config',
        'composition-presets',
        'client-local-runtime.preset.json',
      ),
    );
    await presetFile.parent.create(recursive: true);
    await presetFile.writeAsString('{}', flush: true);
    final nested = Directory(p.join(repo.path, 'apps/desktop'));
    await nested.create(recursive: true);

    final store = PlatformLocalRuntimePreferencesStore(
      currentDirectoryOverride: nested.path,
    );
    final preferences = await store.load(
      PortableDataRoot(dataDirectoryOverride: data),
    );

    expect(preferences.sourceRoot, repo.path);
    expect(preferences.presetConfig, presetFile.path);
    expect(preferences.port, LocalRuntimePreferences.defaultPort);
  });

  test('saves and reloads explicit local runtime preferences', () async {
    final data = await Directory.systemTemp.createTemp('lico-runtime-prefs-');
    addTearDown(() => data.delete(recursive: true));
    final portableData = PortableDataRoot(dataDirectoryOverride: data);
    const store = PlatformLocalRuntimePreferencesStore();

    await store.save(
      portableData,
      const LocalRuntimePreferences(
        sourceRoot: '/repo',
        presetConfig: '/repo/preset.json',
        port: 17329,
      ),
    );

    final loaded = await store.load(portableData);
    expect(loaded.sourceRoot, '/repo');
    expect(loaded.presetConfig, '/repo/preset.json');
    expect(loaded.port, 17329);

    final raw =
        jsonDecode(
              await File(
                p.join(
                  data.path,
                  'lico-client',
                  'local-runtime-preferences.json',
                ),
              ).readAsString(),
            )
            as Map<String, dynamic>;
    expect(raw['schemaVersion'], LocalRuntimePreferences.currentSchemaVersion);
  });
}
