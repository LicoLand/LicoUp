import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/platform/native_client/agent_service.dart';
import 'package:licoup/src/platform/native_client/native_cli_runtime_context.dart';
import 'package:licoup/src/platform/storage/portable_data_root.dart';

void main() {
  group('NativeCliRuntimeContext', () {
    late List<String> capturedArgs;
    late Map<String, String>? capturedEnv;
    late Directory portableDir;
    late File cliBinary;
    late AgentService service;

    setUp(() async {
      capturedArgs = [];
      capturedEnv = null;
      portableDir = await Directory.systemTemp.createTemp(
        'lico-portable-data-',
      );
      cliBinary = File('${portableDir.path}${Platform.pathSeparator}licoup');
      await cliBinary.writeAsString('');
      service = AgentService(
        dataDirectory: () async => portableDir.path,
        resolveCliBinary: () async => cliBinary,
        runCliExecutable: (executable, args, env) async {
          capturedArgs = args;
          capturedEnv = env;
          return ProcessResult(0, 0, '{"ok":true, "candidates":[]}', '');
        },
      );
    });

    tearDown(() async {
      if (await portableDir.exists()) {
        await portableDir.delete(recursive: true);
      }
    });

    test('scanTargets passes LICOUP_HOME', () async {
      await service.scanTargets();
      expect(capturedArgs, [
        'targets',
        'scan',
        '--include-accessible-environments',
        'true',
        '--include-history-model-catalog',
        'false',
      ]);
      expect(capturedEnv?['LICOUP_HOME'], portableDir.path);
      expect(capturedEnv?['LICOUP_CLIENT_PID'], '$pid');
      final parentPath = Platform.environment['PATH']?.trim() ?? '';
      if (parentPath.isNotEmpty && parentPath.length <= 32 * 1024) {
        expect(capturedEnv?['PATH'], parentPath);
      }
      if (Platform.isMacOS) {
        expect(
          capturedEnv?['LICO_SECURE_MESH_MACOS_USER_PRESENCE_REQUIRED'],
          'production',
        );
      }
    });

    test('addTarget passes LICOUP_HOME', () async {
      await service.addTarget(target: 'opencode');
      expect(capturedArgs, ['targets', 'add', '--target', 'opencode']);
      expect(capturedEnv?['LICOUP_HOME'], portableDir.path);
    });

    test('inspectTarget passes LICOUP_HOME', () async {
      await service.inspectTarget('opencode');
      expect(capturedArgs, [
        'targets',
        'inspect',
        'opencode',
        '--include-accessible-environments',
        'true',
        '--enable-agent-cli-model-lookup',
        'true',
      ]);
      expect(capturedEnv?['LICOUP_HOME'], portableDir.path);
    });

    test('restoreSnapshot passes LICOUP_HOME', () async {
      await service.restoreSnapshot('snap-1');
      expect(capturedArgs, ['snapshots', 'restore', 'snap-1']);
      expect(capturedEnv?['LICOUP_HOME'], portableDir.path);
    });

    test('listSnapshots passes LICOUP_HOME', () async {
      await service.listSnapshots(target: 'opencode');
      expect(capturedArgs, ['snapshots', 'list', '--target', 'opencode']);
      expect(capturedEnv?['LICOUP_HOME'], portableDir.path);
    });

    test('listPairings passes LICOUP_HOME', () async {
      await service.listPairings(agent: 'codex');
      expect(capturedArgs, ['agents', 'pair', 'list', '--agent', 'codex']);
      expect(capturedEnv?['LICOUP_HOME'], portableDir.path);
    });

    test('listSkills passes LICOUP_HOME', () async {
      await service.listSkills(agent: 'codex');
      expect(capturedArgs, ['skill', 'list', '--agent', 'codex']);
      expect(capturedEnv?['LICOUP_HOME'], portableDir.path);
    });

    test('without dataDirectory, env does not contain LICOUP_HOME', () async {
      final noDataService = AgentService(
        resolveCliBinary: () async => cliBinary,
        runCliExecutable: (executable, args, env) async {
          capturedArgs = args;
          capturedEnv = env;
          return ProcessResult(0, 0, '{"ok":true}', '');
        },
      );
      await noDataService.scanTargets();
      expect(capturedEnv?['LICOUP_HOME'], isNull);
      expect(capturedEnv?['LICOUP_CLIENT_PID'], '$pid');
      if (Platform.isMacOS) {
        expect(
          capturedEnv?['LICO_SECURE_MESH_MACOS_USER_PRESENCE_REQUIRED'],
          'production',
        );
      } else {
        expect(capturedEnv?['LICOUP_HOME'], isNull);
        final parentPath = Platform.environment['PATH']?.trim() ?? '';
        if (parentPath.isNotEmpty && parentPath.length <= 32 * 1024) {
          expect(capturedEnv?['PATH'], parentPath);
        }
      }
    });

    test(
      'data-home mutation environment does not resolve the current root',
      () async {
        var resolvedDataDirectory = false;
        final context = NativeCliRuntimeContext(
          dataDirectory: () async {
            resolvedDataDirectory = true;
            throw StateError('the saved data root is unavailable');
          },
        );

        final environment = await context.buildDataHomeMutationEnvironment();

        expect(resolvedDataDirectory, isFalse);
        expect(environment?['LICOUP_HOME'], isNull);
        expect(environment?['LICOUP_CLIENT_PID'], '$pid');
      },
    );

    test(
      'saved selection is resolved by the child locator, not inherited env',
      () async {
        final saved = Directory('${portableDir.path}/saved-root');
        await saved.create();
        final locator = _dataHomeLocator(portableDir.path);
        await locator.parent.create(recursive: true);
        await locator.writeAsString(saved.path);
        final root = PortableDataRoot(
          environmentOverride: _homeEnvironment(portableDir.path),
        );
        final context = NativeCliRuntimeContext(
          dataHomeSelection: root.dataHomeSelection,
        );

        final environment = await context.buildEnvironment();

        expect(
          (await root.dataHomeSelection()).source,
          DataHomeSelectionSource.saved,
        );
        expect(environment?['LICOUP_HOME'], '');
        expect(environment?['LICOUP_PORTABLE_DIR'], '');
      },
    );

    test(
      'explicit and legacy user selections become the effective root only',
      () async {
        for (final variable in ['LICOUP_HOME', 'LICOUP_PORTABLE_DIR']) {
          final selected = '${portableDir.path}/$variable';
          final environmentOverride = <String, String>{
            ..._homeEnvironment(portableDir.path),
            variable: selected,
          };
          final root = PortableDataRoot(
            environmentOverride: environmentOverride,
          );
          final context = NativeCliRuntimeContext(
            dataHomeSelection: root.dataHomeSelection,
          );

          final environment = await context.buildEnvironment();

          expect((await root.dataHomeSelection()).path, selected);
          expect(environment?['LICOUP_HOME'], selected);
          expect(environment?['LICOUP_PORTABLE_DIR'], '');
        }
      },
    );
  });

  group('resolveCliBinaryFor', () {
    late Directory bundleDir;
    late File appExecutable;
    late File sidecarBinary;

    setUp(() async {
      bundleDir = await Directory.systemTemp.createTemp('lico-cli-resolve-');
      appExecutable = File('${bundleDir.path}/licoup');
      sidecarBinary = File('${bundleDir.path}/licoup-cli');
    });

    tearDown(() async {
      if (await bundleDir.exists()) {
        await bundleDir.delete(recursive: true);
      }
    });

    test('resolves the bundled licoup-cli sidecar, never the client', () async {
      await appExecutable.writeAsString('app');
      await sidecarBinary.writeAsString('cli');
      final resolved = await NativeCliRuntimeContext().resolveCliBinaryFor(
        executablePath: appExecutable.path,
        environment: const {},
        workingDirectory: bundleDir.path,
      );
      expect(resolved?.path, await sidecarBinary.resolveSymbolicLinks());
    });

    test(
      'returns null when the only sibling binary is the client itself',
      () async {
        await appExecutable.writeAsString('app');
        final resolved = await NativeCliRuntimeContext().resolveCliBinaryFor(
          executablePath: appExecutable.path,
          environment: const {},
          workingDirectory: bundleDir.path,
        );
        expect(resolved, isNull);
      },
    );

    test('ignores LICO_CLIENT_PATH pointing at the client itself', () async {
      await appExecutable.writeAsString('app');
      final resolved = await NativeCliRuntimeContext().resolveCliBinaryFor(
        executablePath: appExecutable.path,
        environment: {'LICO_CLIENT_PATH': appExecutable.path},
        workingDirectory: bundleDir.path,
      );
      expect(resolved, isNull);
    });

    test(
      'installed app requires its custody helper without developer fallback',
      () async {
        final macos = Directory('${bundleDir.path}/LicoUp.app/Contents/MacOS');
        await macos.create(recursive: true);
        final app = File('${macos.path}/licoup');
        await app.writeAsString('app');
        await File('${macos.path}/licoup-cli').writeAsString('old-cli');
        await sidecarBinary.writeAsString('external-cli');
        final resolved = await NativeCliRuntimeContext().resolveCliBinaryFor(
          executablePath: app.path,
          environment: {'LICO_CLIENT_PATH': sidecarBinary.path},
          workingDirectory: bundleDir.path,
        );
        expect(resolved, isNull);
      },
    );

    test(
      'installed app rejects a custody helper symlink outside its bundle',
      () async {
        final macos = Directory('${bundleDir.path}/LicoUp.app/Contents/MacOS');
        await macos.create(recursive: true);
        final app = File('${macos.path}/licoup');
        await app.writeAsString('app');
        await sidecarBinary.writeAsString('external-cli');
        final helper = Link(
          '${macos.parent.path}/Helpers/LicoUpCustody.app/Contents/MacOS/licoup-cli',
        );
        await helper.parent.create(recursive: true);
        await helper.create(sidecarBinary.path);
        final resolved = await NativeCliRuntimeContext().resolveCliBinaryFor(
          executablePath: app.path,
          environment: const {},
          workingDirectory: bundleDir.path,
        );
        expect(resolved, isNull);
      },
      skip: Platform.isWindows,
    );

    test(
      'installed app bundle ignores CARGO_TARGET_DIR debug sidecars',
      () async {
        final appRoot = await Directory.systemTemp.createTemp('lico-app-');
        addTearDown(() => appRoot.delete(recursive: true));
        final macos = Directory('${appRoot.path}/LicoUp.app/Contents/MacOS');
        await macos.create(recursive: true);
        final appExecutable = File('${macos.path}/licoup');
        final bundledCli = File(
          '${macos.parent.path}/Helpers/LicoUpCustody.app/Contents/MacOS/licoup-cli',
        );
        await bundledCli.parent.create(recursive: true);
        final cargoDir = await Directory.systemTemp.createTemp('lico-cargo-');
        addTearDown(() => cargoDir.delete(recursive: true));
        final cargoCli = File('${cargoDir.path}/debug/licoup-cli');
        await cargoCli.parent.create(recursive: true);
        await appExecutable.writeAsString('app');
        await bundledCli.writeAsString('bundled');
        await cargoCli.writeAsString('cargo-debug');
        final resolved = await NativeCliRuntimeContext().resolveCliBinaryFor(
          executablePath: appExecutable.path,
          environment: {'CARGO_TARGET_DIR': cargoDir.path},
          workingDirectory: cargoDir.path,
        );
        expect(resolved?.path, await bundledCli.resolveSymbolicLinks());
      },
    );

    test(
      'installed app bundle ignores an external LICO_CLIENT_PATH override',
      () async {
        final appRoot = await Directory.systemTemp.createTemp('lico-app-');
        addTearDown(() => appRoot.delete(recursive: true));
        final macos = Directory('${appRoot.path}/LicoUp.app/Contents/MacOS');
        await macos.create(recursive: true);
        final appExecutable = File('${macos.path}/licoup');
        final bundledCli = File(
          '${macos.parent.path}/Helpers/LicoUpCustody.app/Contents/MacOS/licoup-cli',
        );
        await bundledCli.parent.create(recursive: true);
        final externalDir = await Directory.systemTemp.createTemp(
          'lico-external-cli-',
        );
        addTearDown(() => externalDir.delete(recursive: true));
        final externalCli = File('${externalDir.path}/licoup-cli');
        await appExecutable.writeAsString('app');
        await bundledCli.writeAsString('bundled');
        await externalCli.writeAsString('external');

        final resolved = await NativeCliRuntimeContext().resolveCliBinaryFor(
          executablePath: appExecutable.path,
          environment: {'LICO_CLIENT_PATH': externalCli.path},
          workingDirectory: externalDir.path,
        );

        expect(resolved?.path, await bundledCli.resolveSymbolicLinks());
      },
    );
  });
}

Map<String, String> _homeEnvironment(String home) => <String, String>{
  'HOME': home,
  'USERPROFILE': home,
  'APPDATA': p.join(home, 'AppData', 'Roaming'),
};

File _dataHomeLocator(String home) {
  if (Platform.isMacOS) {
    return File(
      p.join(home, 'Library', 'Application Support', 'LicoUp', 'data-home'),
    );
  }
  if (Platform.isWindows) {
    return File(p.join(home, 'AppData', 'Roaming', 'LicoUp', 'data-home'));
  }
  return File(p.join(home, '.config', 'licoup', 'data-home'));
}
