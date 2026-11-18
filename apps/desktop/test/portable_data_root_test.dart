import 'dart:convert';
import 'dart:io';

import 'package:licoup/src/platform/storage/portable_data_root.dart';
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

      final manifestFile = File('${directory.path}/.licoup-workspace.json');
      expect(manifestFile.exists(), completion(isTrue));
      expect(
        manifest.schemaVersion,
        ClientWorkspaceManifest.currentSchemaVersion,
      );
      expect(manifest.appId, ClientWorkspaceManifest.licoUpAppId);
      expect(manifest.workspaceId, isNotEmpty);

      final refreshed = await portableData.loadWorkspaceManifest();
      expect(refreshed.schemaVersion, manifest.schemaVersion);
      expect(refreshed.appId, manifest.appId);
      expect(refreshed.workspaceId, manifest.workspaceId);
      expect(refreshed.updatedAt.compareTo(manifest.updatedAt), greaterThan(0));
    },
  );

  test(
    'rejects a malformed manifest without replacing durable state',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lico-workspace-corrupt-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final manifestFile = File('${directory.path}/.licoup-workspace.json');
      await manifestFile.writeAsString('{not-json', flush: true);

      final portableData = PortableDataRoot(dataDirectoryOverride: directory);
      await expectLater(
        portableData.loadWorkspaceManifest(),
        throwsA(isA<StateError>()),
      );
      final entries = await directory.list().map((e) => e.path).toList();
      expect(entries.any((entry) => entry.contains('.corrupt.')), isFalse);
      expect(manifestFile.exists(), completion(isTrue));
      expect(await manifestFile.readAsString(), '{not-json');
    },
  );

  test('throws when workspace manifest app id is incompatible', () async {
    final directory = await Directory.systemTemp.createTemp(
      'lico-workspace-bad-app-id-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final manifestFile = File('${directory.path}/.licoup-workspace.json');
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
    final manifestFile = File('${directory.path}/.licoup-workspace.json');
    await manifestFile.writeAsString(
      jsonEncode({
        'schemaVersion': 999,
        'appId': ClientWorkspaceManifest.licoUpAppId,
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
    final manifestFile = File('${directory.path}/.licoup-workspace.json');
    await manifestFile.writeAsString(
      jsonEncode({
        'schemaVersion': 1,
        'appId': ClientWorkspaceManifest.licoUpAppId,
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
    final home = await Directory.systemTemp.createTemp('licoup-home-');
    addTearDown(() => home.delete(recursive: true));
    final portableData = PortableDataRoot(
      environmentOverride: {'HOME': home.path},
    );
    final first = await portableData.dataDirectory();
    final second = await portableData.dataDirectory();

    expect(first.path, second.path);
    expect(first.path, p.join(home.path, '.lico-up'));
    expect(
      await File('${first.path}/.licoup-workspace.json').exists(),
      isFalse,
    );
  });

  test('resolves Windows home from HOMEDRIVE and HOMEPATH', () async {
    const drive = 'C:';
    const path = r'\Users\Fixture';
    final portableData = PortableDataRoot(
      environmentOverride: {'HOMEDRIVE': drive, 'HOMEPATH': path},
    );

    final selection = await portableData.dataHomeSelection();

    expect(selection.path, p.normalize(p.join('$drive$path', '.lico-up')));
    expect(selection.source, DataHomeSelectionSource.defaultHome);
  }, skip: !Platform.isWindows);

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
    expect(topLevelEntries, {'client-state'});
  });

  test('bundled desktop honors new home before the published alias', () async {
    final home = await Directory.systemTemp.createTemp('licoup-mac-home-');
    final envDirectory = await Directory.systemTemp.createTemp(
      'lico-env-portable-',
    );
    final newRoot = await Directory.systemTemp.createTemp('lico-new-home-');
    addTearDown(() => home.delete(recursive: true));
    addTearDown(() => envDirectory.delete(recursive: true));
    addTearDown(() => newRoot.delete(recursive: true));

    final portableData = PortableDataRoot(
      environmentOverride: {
        'LICOUP_HOME': newRoot.path,
        'LICOUP_PORTABLE_DIR': envDirectory.path,
        'HOME': home.path,
      },
    );

    final resolved = await portableData.dataDirectory();

    expect(resolved.path, newRoot.path);
    expect(resolved.path, isNot(envDirectory.path));
    expect(
      await File('${resolved.path}/.licoup-workspace.json').exists(),
      isFalse,
    );
  });

  test(
    'relative environment roots resolve against the process directory',
    () async {
      for (final (variable, source) in [
        ('LICOUP_HOME', DataHomeSelectionSource.explicitEnvironment),
        ('LICOUP_PORTABLE_DIR', DataHomeSelectionSource.legacyEnvironment),
      ]) {
        final selection = await PortableDataRoot(
          environmentOverride: {variable: 'relative/licoup-data'},
        ).dataHomeSelection();

        expect(selection.path, p.normalize(p.absolute('relative/licoup-data')));
        expect(selection.source, source);
      }
    },
  );

  test(
    'desktop reads a saved root when environment selection is absent',
    () async {
      final home = await Directory.systemTemp.createTemp('licoup-saved-home-');
      final savedRoot = await Directory.systemTemp.createTemp(
        'licoup-saved-root-',
      );
      addTearDown(() => home.delete(recursive: true));
      addTearDown(() => savedRoot.delete(recursive: true));
      final locatorDirectory = _locatorDirectory(home.path);
      await locatorDirectory.create(recursive: true);
      await File(
        p.join(locatorDirectory.path, 'data-home'),
      ).writeAsString('${savedRoot.path}\n', flush: true);
      final portableData = PortableDataRoot(
        environmentOverride: {'HOME': home.path},
      );

      final selection = await portableData.dataHomeSelection();

      expect(selection.path, savedRoot.path);
      expect(selection.source, DataHomeSelectionSource.saved);
      expect((await portableData.dataDirectory()).path, savedRoot.path);
    },
  );

  test(
    'empty Windows APPDATA uses the home-based locator directory',
    () async {
      final home = await Directory.systemTemp.createTemp(
        'licoup-appdata-fallback-home-',
      );
      final savedRoot = await Directory.systemTemp.createTemp(
        'licoup-appdata-fallback-root-',
      );
      addTearDown(() => home.delete(recursive: true));
      addTearDown(() => savedRoot.delete(recursive: true));
      final locatorDirectory = Directory(
        p.join(home.path, 'AppData', 'Roaming', 'LicoUp'),
      );
      await locatorDirectory.create(recursive: true);
      await File(
        p.join(locatorDirectory.path, 'data-home'),
      ).writeAsString('${savedRoot.path}\n', flush: true);

      final selection = await PortableDataRoot(
        environmentOverride: {'HOME': home.path, 'APPDATA': '  '},
      ).dataHomeSelection();

      expect(selection.path, savedRoot.path);
      expect(selection.source, DataHomeSelectionSource.saved);
    },
    skip: !Platform.isWindows,
  );

  test('saved-root locator uses the native 32 KiB read bound', () async {
    final home = await Directory.systemTemp.createTemp('licoup-bounded-home-');
    addTearDown(() => home.delete(recursive: true));
    final locatorDirectory = _locatorDirectory(home.path);
    await locatorDirectory.create(recursive: true);
    final locator = File(p.join(locatorDirectory.path, 'data-home'));
    final atLimit = '/${'x' * (32 * 1024 - 1)}';
    await locator.writeAsString(atLimit, flush: true);

    final accepted = await PortableDataRoot(
      environmentOverride: {'HOME': home.path},
    ).dataHomeSelection();
    expect(accepted.path, atLimit);
    expect(accepted.source, DataHomeSelectionSource.saved);

    await locator.writeAsString('${atLimit}x', flush: true);
    await expectLater(
      PortableDataRoot(
        environmentOverride: {'HOME': home.path},
      ).dataHomeSelection(),
      throwsA(isA<FormatException>()),
    );
  });

  test('published root alias remains available below LICOUP_HOME', () async {
    final home = await Directory.systemTemp.createTemp('licoup-alias-home-');
    final aliasRoot = await Directory.systemTemp.createTemp(
      'licoup-alias-root-',
    );
    addTearDown(() => home.delete(recursive: true));
    addTearDown(() => aliasRoot.delete(recursive: true));
    final portableData = PortableDataRoot(
      environmentOverride: {
        'HOME': home.path,
        'LICOUP_PORTABLE_DIR': aliasRoot.path,
      },
    );

    final selection = await portableData.dataHomeSelection();

    expect(selection.path, aliasRoot.path);
    expect(selection.source, DataHomeSelectionSource.legacyEnvironment);
  });

  test(
    'missing saved root does not create a replacement default root',
    () async {
      final home = await Directory.systemTemp.createTemp(
        'licoup-missing-home-',
      );
      final missingRoot = p.join(home.path, 'removed-volume', 'LicoUp');
      addTearDown(() => home.delete(recursive: true));
      final locatorDirectory = _locatorDirectory(home.path);
      await locatorDirectory.create(recursive: true);
      await File(
        p.join(locatorDirectory.path, 'data-home'),
      ).writeAsString(missingRoot);
      final portableData = PortableDataRoot(
        environmentOverride: {'HOME': home.path},
      );

      await expectLater(
        portableData.dataDirectory(),
        throwsA(isA<MissingSavedDataHome>()),
      );
      expect(await Directory(p.join(home.path, '.lico-up')).exists(), isFalse);
    },
  );

  test(
    'saved-root recovery detects reattachment without creating a root',
    () async {
      final home = await Directory.systemTemp.createTemp(
        'licoup-recovery-home-',
      );
      final missingRoot = p.join(home.path, 'removed-volume', 'LicoUp');
      addTearDown(() => home.delete(recursive: true));
      final locatorDirectory = _locatorDirectory(home.path);
      await locatorDirectory.create(recursive: true);
      await File(
        p.join(locatorDirectory.path, 'data-home'),
      ).writeAsString('$missingRoot\n', flush: true);
      final portableData = PortableDataRoot(
        environmentOverride: {'HOME': home.path},
      );

      expect(await portableData.missingSavedDataHome(), isTrue);
      expect(await Directory(missingRoot).exists(), isFalse);

      await Directory(missingRoot).create(recursive: true);
      expect(await portableData.missingSavedDataHome(), isFalse);
    },
  );

  test(
    'cached saved root disappearance is rejected before client state recreation',
    () async {
      final home = await Directory.systemTemp.createTemp(
        'licoup-disappearing-home-boot-',
      );
      final savedRoot = await Directory.systemTemp.createTemp(
        'licoup-disappearing-saved-root-',
      );
      addTearDown(() => home.delete(recursive: true));
      final locatorDirectory = _locatorDirectory(home.path);
      await locatorDirectory.create(recursive: true);
      await File(
        p.join(locatorDirectory.path, 'data-home'),
      ).writeAsString('${savedRoot.path}\n', flush: true);
      final portableData = PortableDataRoot(
        environmentOverride: {'HOME': home.path},
      );

      expect((await portableData.dataDirectory()).path, savedRoot.path);
      await savedRoot.delete(recursive: true);

      await expectLater(
        portableData.clientDirectory(),
        throwsA(isA<MissingSavedDataHome>()),
      );
      expect(await savedRoot.exists(), isFalse);
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
      environmentOverride: {'LICOUP_PORTABLE_DIR': envDirectory.path},
      mobileRuntimeOverride: true,
      applicationSupportDirectoryResolver: () async => applicationSupport,
    );

    final resolved = await portableData.dataDirectory();

    expect(
      resolved.path,
      p.join(applicationSupport.path, 'LicoUp', 'portable-data'),
    );
    expect(
      await Directory(
        p.join(executableDirectory.path, 'portable-data'),
      ).exists(),
      isFalse,
    );
    expect(await Directory(envDirectory.path).list().isEmpty, isTrue);
  });

  test('macos firmlink home prefix collapses to the same state root', () {
    String posix(List<String> parts) => '/${parts.join('/')}';
    expect(
      PortableDataRoot.stripMacosDataVolume(
        posix(['System', 'Volumes', 'Data', 'Users', 'fixture']),
      ),
      posix(['Users', 'fixture']),
    );
    expect(
      PortableDataRoot.stripMacosDataVolume(posix(['Users', 'fixture'])),
      posix(['Users', 'fixture']),
    );
    expect(
      PortableDataRoot.stripMacosDataVolume(
        PortableDataRoot.macosDataVolumePrefix,
      ),
      '/',
    );
  });
}

Directory _locatorDirectory(String home) {
  if (Platform.isMacOS) {
    return Directory(p.join(home, 'Library', 'Application Support', 'LicoUp'));
  }
  if (Platform.isWindows) {
    return Directory(p.join(home, 'AppData', 'Roaming', 'LicoUp'));
  }
  return Directory(p.join(home, '.config', 'licoup'));
}
