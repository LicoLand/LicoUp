import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_client/src/services/agent_service.dart';

void main() {
  group('PortableDataCliContract', () {
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
        '${portableDir.path}${Platform.pathSeparator}lico-client',
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

    test('scanTargets passes LICO_PORTABLE_DIR', () async {
      await service.scanTargets();
      expect(capturedArgs, [
        'targets',
        'scan',
        '--include-accessible-environments',
        'false',
      ]);
      expect(capturedEnv?['LICO_PORTABLE_DIR'], portableDir.path);
    });

    test('addTarget passes LICO_PORTABLE_DIR', () async {
      await service.addTarget(target: 'opencode');
      expect(capturedArgs, ['targets', 'add', '--target', 'opencode']);
      expect(capturedEnv?['LICO_PORTABLE_DIR'], portableDir.path);
    });

    test('inspectTarget passes LICO_PORTABLE_DIR', () async {
      await service.inspectTarget('opencode');
      expect(capturedArgs, ['targets', 'inspect', 'opencode']);
      expect(capturedEnv?['LICO_PORTABLE_DIR'], portableDir.path);
    });

    test('planTargetConfig passes LICO_PORTABLE_DIR', () async {
      await service.planTargetConfig('opencode');
      expect(capturedArgs, ['mcp', 'config', 'plan', '--target', 'opencode']);
      expect(capturedEnv?['LICO_PORTABLE_DIR'], portableDir.path);
    });

    test('restoreSnapshot passes LICO_PORTABLE_DIR', () async {
      await service.restoreSnapshot('snap-1');
      expect(capturedArgs, ['snapshots', 'restore', 'snap-1']);
      expect(capturedEnv?['LICO_PORTABLE_DIR'], portableDir.path);
    });

    test('mcpPluginStatus passes LICO_PORTABLE_DIR', () async {
      await service.mcpPluginStatus(target: 'opencode');
      expect(capturedArgs, ['mcp', 'plugin', 'status', '--target', 'opencode']);
      expect(capturedEnv?['LICO_PORTABLE_DIR'], portableDir.path);
    });

    test('updateMcpPlugin passes LICO_PORTABLE_DIR', () async {
      await service.updateMcpPlugin(target: 'opencode');
      expect(capturedArgs, ['mcp', 'plugin', 'update', '--target', 'opencode']);
      expect(capturedEnv?['LICO_PORTABLE_DIR'], portableDir.path);
    });

    test('rollbackMcpPlugin passes LICO_PORTABLE_DIR', () async {
      await service.rollbackMcpPlugin(target: 'opencode', snapshotId: 'snap-1');
      expect(capturedArgs, [
        'mcp',
        'plugin',
        'rollback',
        '--target',
        'opencode',
        '--snapshot-id',
        'snap-1',
      ]);
      expect(capturedEnv?['LICO_PORTABLE_DIR'], portableDir.path);
    });

    test('listSnapshots passes LICO_PORTABLE_DIR', () async {
      await service.listSnapshots(target: 'opencode');
      expect(capturedArgs, ['snapshots', 'list', '--target', 'opencode']);
      expect(capturedEnv?['LICO_PORTABLE_DIR'], portableDir.path);
    });

    test('listPairings passes LICO_PORTABLE_DIR', () async {
      await service.listPairings(agent: 'codex');
      expect(capturedArgs, ['agents', 'pair', 'list', '--agent', 'codex']);
      expect(capturedEnv?['LICO_PORTABLE_DIR'], portableDir.path);
    });

    test('listSkills passes LICO_PORTABLE_DIR', () async {
      await service.listSkills(agent: 'codex');
      expect(capturedArgs, ['skill', 'list', '--agent', 'codex']);
      expect(capturedEnv?['LICO_PORTABLE_DIR'], portableDir.path);
    });

    test('listModelProfiles passes LICO_PORTABLE_DIR', () async {
      await service.listModelProfiles();
      expect(capturedArgs, ['model', 'profiles', 'list']);
      expect(capturedEnv?['LICO_PORTABLE_DIR'], portableDir.path);
    });

    test(
      'without dataDirectory, env does not contain LICO_PORTABLE_DIR',
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
        expect(capturedEnv, isNull);
      },
    );
  });
}
