import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/platform/native_client/agent_service.dart';
import 'package:licoup/src/platform/native_client/native_cli_runtime_context.dart';

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

    test('scanTargets passes LICOUP_PORTABLE_DIR', () async {
      await service.scanTargets();
      expect(capturedArgs, [
        'targets',
        'scan',
        '--include-accessible-environments',
        'true',
        '--include-history-model-catalog',
        'false',
      ]);
      expect(capturedEnv?['LICOUP_PORTABLE_DIR'], portableDir.path);
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

    test('addTarget passes LICOUP_PORTABLE_DIR', () async {
      await service.addTarget(target: 'opencode');
      expect(capturedArgs, ['targets', 'add', '--target', 'opencode']);
      expect(capturedEnv?['LICOUP_PORTABLE_DIR'], portableDir.path);
    });

    test('inspectTarget passes LICOUP_PORTABLE_DIR', () async {
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
      expect(capturedEnv?['LICOUP_PORTABLE_DIR'], portableDir.path);
    });

    test('restoreSnapshot passes LICOUP_PORTABLE_DIR', () async {
      await service.restoreSnapshot('snap-1');
      expect(capturedArgs, ['snapshots', 'restore', 'snap-1']);
      expect(capturedEnv?['LICOUP_PORTABLE_DIR'], portableDir.path);
    });

    test('listSnapshots passes LICOUP_PORTABLE_DIR', () async {
      await service.listSnapshots(target: 'opencode');
      expect(capturedArgs, ['snapshots', 'list', '--target', 'opencode']);
      expect(capturedEnv?['LICOUP_PORTABLE_DIR'], portableDir.path);
    });

    test('listPairings passes LICOUP_PORTABLE_DIR', () async {
      await service.listPairings(agent: 'codex');
      expect(capturedArgs, ['agents', 'pair', 'list', '--agent', 'codex']);
      expect(capturedEnv?['LICOUP_PORTABLE_DIR'], portableDir.path);
    });

    test('listSkills passes LICOUP_PORTABLE_DIR', () async {
      await service.listSkills(agent: 'codex');
      expect(capturedArgs, ['skill', 'list', '--agent', 'codex']);
      expect(capturedEnv?['LICOUP_PORTABLE_DIR'], portableDir.path);
    });

    test(
      'without dataDirectory, env does not contain LICOUP_PORTABLE_DIR',
      () async {
        final noDataService = AgentService(
          resolveCliBinary: () async => cliBinary,
          runCliExecutable: (executable, args, env) async {
            capturedArgs = args;
            capturedEnv = env;
            return ProcessResult(0, 0, '{"ok":true}', '');
          },
        );
        await noDataService.scanTargets();
        expect(capturedEnv?['LICOUP_PORTABLE_DIR'], isNull);
        expect(capturedEnv?['LICOUP_CLIENT_PID'], '$pid');
        if (Platform.isMacOS) {
          expect(
            capturedEnv?['LICO_SECURE_MESH_MACOS_USER_PRESENCE_REQUIRED'],
            'production',
          );
        } else {
          expect(capturedEnv?['LICOUP_PORTABLE_DIR'], isNull);
          final parentPath = Platform.environment['PATH']?.trim() ?? '';
          if (parentPath.isNotEmpty && parentPath.length <= 32 * 1024) {
            expect(capturedEnv?['PATH'], parentPath);
          }
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
      'installed app bundle ignores CARGO_TARGET_DIR debug sidecars',
      () async {
        final appRoot = await Directory.systemTemp.createTemp('lico-app-');
        addTearDown(() => appRoot.delete(recursive: true));
        final macos = Directory('${appRoot.path}/LicoUp.app/Contents/MacOS');
        await macos.create(recursive: true);
        final appExecutable = File('${macos.path}/licoup');
        final bundledCli = File('${macos.path}/licoup-cli');
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
  });
}
