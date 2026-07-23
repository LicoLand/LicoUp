import 'dart:convert';
import 'dart:io';

import 'package:flutter_client/src/platform/storage/portable_data_root.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test(
    'creates and updates workspace manifest in override directory',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lico-workspace-override-',
      );
      addTearDown(() => directory.delete(recursive: true));

      final portableData = PortableDataRoot(dataDirectoryOverride: directory);
      final manifest = await portableData.loadWorkspaceManifest();

      final manifestFile = File('${directory.path}/.licoarc-workspace.json');
      expect(manifestFile.exists(), completion(isTrue));
      expect(
        manifest.schemaVersion,
        ClientWorkspaceManifest.currentSchemaVersion,
      );
      expect(manifest.appId, ClientWorkspaceManifest.licoArcAppId);
      expect(manifest.workspaceId, isNotEmpty);

      final refreshed = await portableData.loadWorkspaceManifest();
      expect(refreshed.schemaVersion, manifest.schemaVersion);
      expect(refreshed.appId, manifest.appId);
      expect(refreshed.workspaceId, manifest.workspaceId);
      expect(refreshed.updatedAt.compareTo(manifest.updatedAt), greaterThan(0));
    },
  );

  test('renames malformed manifest and recreates a valid one', () async {
    final directory = await Directory.systemTemp.createTemp(
      'lico-workspace-corrupt-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final manifestFile = File('${directory.path}/.licoarc-workspace.json');
    await manifestFile.writeAsString('{not-json', flush: true);

    final portableData = PortableDataRoot(dataDirectoryOverride: directory);
    final manifest = await portableData.loadWorkspaceManifest();

    expect(manifest.workspaceId, isNotEmpty);
    final entries = await directory.list().map((e) => e.path).toList();
    expect(entries.any((entry) => entry.contains('.corrupt.')), isTrue);
    expect(manifestFile.exists(), completion(isTrue));
  });

  test('throws when workspace manifest app id is incompatible', () async {
    final directory = await Directory.systemTemp.createTemp(
      'lico-workspace-bad-app-id-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final manifestFile = File('${directory.path}/.licoarc-workspace.json');
    await manifestFile.writeAsString(
      jsonEncode({
        'schemaVersion': 1,
        'appId': 'wrong-client',
        'workspaceId': 'workspace-id',
        'createdAt': DateTime(2020).toUtc().toIso8601String(),
        'updatedAt': DateTime(2020).toUtc().toIso8601String(),
      }),
    );

    final portableData = PortableDataRoot(dataDirectoryOverride: directory);
    await expectLater(
      portableData.loadWorkspaceManifest(),
      throwsA(isA<StateError>()),
    );
  });

  test('throws when workspace schema version is incompatible', () async {
    final directory = await Directory.systemTemp.createTemp(
      'lico-workspace-bad-schema-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final manifestFile = File('${directory.path}/.licoarc-workspace.json');
    await manifestFile.writeAsString(
      jsonEncode({
        'schemaVersion': 999,
        'appId': ClientWorkspaceManifest.licoArcAppId,
        'workspaceId': 'workspace-id',
        'createdAt': DateTime(2020).toUtc().toIso8601String(),
        'updatedAt': DateTime(2020).toUtc().toIso8601String(),
      }),
    );

    final portableData = PortableDataRoot(dataDirectoryOverride: directory);
    await expectLater(
      portableData.loadWorkspaceManifest(),
      throwsA(isA<StateError>()),
    );
  });

  test('throws when workspace id is empty', () async {
    final directory = await Directory.systemTemp.createTemp(
      'lico-workspace-empty-id-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final manifestFile = File('${directory.path}/.licoarc-workspace.json');
    await manifestFile.writeAsString(
      jsonEncode({
        'schemaVersion': 1,
        'appId': ClientWorkspaceManifest.licoArcAppId,
        'workspaceId': '',
        'createdAt': DateTime(2020).toUtc().toIso8601String(),
        'updatedAt': DateTime(2020).toUtc().toIso8601String(),
      }),
    );

    final portableData = PortableDataRoot(dataDirectoryOverride: directory);
    await expectLater(
      portableData.loadWorkspaceManifest(),
      throwsA(isA<StateError>()),
    );
  });

  test('resolves the home dot-directory namespace once', () async {
    final home = await Directory.systemTemp.createTemp('licoarc-home-');
    addTearDown(() => home.delete(recursive: true));
    final portableData = PortableDataRoot(
      environmentOverride: {'HOME': home.path},
    );
    final first = await portableData.dataDirectory();
    final second = await portableData.dataDirectory();

    expect(first.path, second.path);
    expect(first.path, p.join(home.path, '.lico-arc'));
    expect(
      await File('${first.path}/.licoarc-workspace.json').exists(),
      isTrue,
    );
  });

  test('first launch creates only the canonical client state root', () async {
    final directory = await Directory.systemTemp.createTemp(
      'lico-state-root-reset-',
    );
    addTearDown(() => directory.delete(recursive: true));

    final portableData = PortableDataRoot(dataDirectoryOverride: directory);
    final clientState = await portableData.clientDirectory();
    final topLevelEntries = await directory
        .list()
        .map((entry) => p.basename(entry.path))
        .toSet();

    expect(clientState.path, p.join(directory.path, 'client-state'));
    expect(await clientState.list().isEmpty, isTrue);
    expect(topLevelEntries, {
      '.licoarc-workspace.json',
      '.licoarc-workspace.json.lock',
      'client-state',
    });
  });

  test(
    'packaged macOS app uses the home dot directory instead of portable env',
    () async {
      final home = await Directory.systemTemp.createTemp('licoarc-mac-home-');
      final envDirectory = await Directory.systemTemp.createTemp(
        'lico-env-portable-',
      );
      addTearDown(() => home.delete(recursive: true));
      addTearDown(() => envDirectory.delete(recursive: true));

      final portableData = PortableDataRoot(
        environmentOverride: {
          'LICOARC_PORTABLE_DIR': envDirectory.path,
          'HOME': home.path,
        },
        resolvedExecutableOverride: p.join(
          Directory.systemTemp.path,
          'Arc.app',
          'Contents',
          'MacOS',
          'flutter_client',
        ),
      );

      final resolved = await portableData.dataDirectory();

      expect(resolved.path, p.join(home.path, '.lico-arc'));
      expect(resolved.path, isNot(envDirectory.path));
      expect(
        await File('${resolved.path}/.licoarc-workspace.json').exists(),
        isTrue,
      );
    },
  );

  test('mobile app uses application support instead of its bundle', () async {
    final applicationSupport = await Directory.systemTemp.createTemp(
      'lico-mobile-application-support-',
    );
    final executableDirectory = await Directory.systemTemp.createTemp(
      'lico-mobile-bundle-',
    );
    final envDirectory = await Directory.systemTemp.createTemp(
      'lico-mobile-env-portable-',
    );
    addTearDown(() => applicationSupport.delete(recursive: true));
    addTearDown(() => executableDirectory.delete(recursive: true));
    addTearDown(() => envDirectory.delete(recursive: true));

    final portableData = PortableDataRoot(
      environmentOverride: {'LICOARC_PORTABLE_DIR': envDirectory.path},
      resolvedExecutableOverride: p.join(executableDirectory.path, 'Runner'),
      mobileRuntimeOverride: true,
      applicationSupportDirectoryResolver: () async => applicationSupport,
    );

    final resolved = await portableData.dataDirectory();

    expect(
      resolved.path,
      p.join(applicationSupport.path, 'LicoArc', 'portable-data'),
    );
    expect(
      await Directory(
        p.join(executableDirectory.path, 'portable-data'),
      ).exists(),
      isFalse,
    );
    expect(await Directory(envDirectory.path).list().isEmpty, isTrue);
  });
}
