import 'dart:convert';
import 'dart:io';

import 'package:licoup/src/platform/storage/portable_data_root.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('portable data facade uses an injected manifest store', () async {
    final directory = await Directory.systemTemp.createTemp(
      'workspace-manifest-component-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final timestamps = <DateTime>[
      DateTime.utc(2026, 1, 1),
      DateTime.utc(2026, 1, 1, 0, 0, 1),
      DateTime.utc(2026, 1, 1, 0, 0, 2),
      DateTime.utc(2026, 1, 1, 0, 0, 3),
    ].iterator;
    final store = ClientWorkspaceManifestStore(
      clock: () {
        timestamps.moveNext();
        return timestamps.current;
      },
      workspaceIdFactory: (_) => 'workspace-test-id',
    );
    final portableData = PortableDataRoot(
      dataDirectoryOverride: directory,
      workspaceManifestStore: store,
    );

    final manifest = await portableData.loadWorkspaceManifest();

    expect(manifest.workspaceId, 'workspace-test-id');
    expect(manifest.appId, ClientWorkspaceManifest.licoUpAppId);
    expect(manifest.updatedAt, isNot(manifest.createdAt));
  });

  test(
    'manifest validation fails closed without disclosing its path',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'workspace-manifest-validation-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File(
        '${directory.path}/${ClientWorkspaceManifestStore.fileName}',
      );
      await file.writeAsString(
        jsonEncode({
          'schemaVersion': ClientWorkspaceManifest.currentSchemaVersion,
          'appId': 'unexpected-client',
          'workspaceId': 'workspace-test-id',
          'createdAt': '2026-01-01T00:00:00Z',
          'updatedAt': '2026-01-01T00:00:00Z',
        }),
      );
      final store = ClientWorkspaceManifestStore();

      Object? error;
      try {
        await store.loadOrCreate(directory);
      } catch (caught) {
        error = caught;
      }

      expect(error, isA<StateError>());
      expect(error.toString(), isNot(contains(directory.path)));
      expect(
        error.toString(),
        contains('client_workspace_manifest_incompatible'),
      );
    },
  );

  test('manifest store is a normal one-way storage component', () {
    const root = 'lib/src/platform/storage';
    final facade = File('$root/portable_data_root.dart').readAsStringSync();
    final manifest = File(
      '$root/client_workspace_manifest.dart',
    ).readAsStringSync();

    for (final source in [facade, manifest]) {
      expect(
        RegExp(r'^\s*part(?:\s+of)?\s+', multiLine: true).hasMatch(source),
        isFalse,
      );
    }
    expect(manifest, isNot(contains('portable_data_root.dart')));
    expect(
      facade,
      contains('ClientWorkspaceManifestStore? workspaceManifestStore'),
    );
    expect(facade, contains('_workspaceManifestStore.loadOrCreate'));
  });
}
