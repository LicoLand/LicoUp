import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/platform/native_client/agent_service.dart';

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
      cliBinary = File(
        '${portableDir.path}${Platform.pathSeparator}licoup',
      );
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
        'true',
      ]);
      expect(capturedEnv?['LICOUP_PORTABLE_DIR'], portableDir.path);
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
      expect(capturedArgs, ['targets', 'inspect', 'opencode']);
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
        if (Platform.isMacOS) {
          expect(
            capturedEnv?['LICO_SECURE_MESH_MACOS_USER_PRESENCE_REQUIRED'],
            'production',
          );
        } else {
          expect(capturedEnv, isNull);
        }
      },
    );
  });
}
