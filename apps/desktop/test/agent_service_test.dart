import 'dart:convert';
import 'dart:io';

import 'package:flutter_client/src/services/agent_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('target candidate parses target adapter scan shape', () {
    final target = TargetCandidate.fromJson({
      'target': 'opencode',
      'label': 'OpenCode',
      'kind': 'cli',
      'status': 'detected',
      'configured': false,
      'confidence': 0.72,
      'detail': 'OpenCode remote MCP configuration',
      'configPath': '/tmp/opencode.jsonc',
      'binaryPath': '/usr/local/bin/opencode',
      'historyRoots': ['/tmp/opencode-history'],
      'adapterStatus': 'skeleton',
      'manual': true,
    });

    expect(target.target, 'opencode');
    expect(target.label, 'OpenCode');
    expect(target.configured, isFalse);
    expect(target.configPath, '/tmp/opencode.jsonc');
    expect(target.binaryPath, '/usr/local/bin/opencode');
    expect(target.historyRoots, ['/tmp/opencode-history']);
    expect(target.adapterStatus, 'skeleton');
    expect(target.manual, isTrue);
  });

  test('uses injected binary path in CLI execution', () async {
    final tempDir = await Directory.systemTemp.createTemp('lico-cli-binary-');
    addTearDown(() => tempDir.delete(recursive: true));
    final cliPath = File('${tempDir.path}/lico-client');
    final captured = <String>[];
    final agentService = AgentService(
      resolveCliBinary: () async => cliPath,
      runCliExecutable: (executable, args, env) {
        captured.add('$executable:${args.join(' ')}');
        return Future.value(
          ProcessResult(
            0,
            0,
            jsonEncode({
              'ok': true,
              'candidates': [
                {
                  'target': 'opencode',
                  'label': 'OpenCode',
                  'kind': 'cli',
                  'status': 'detected',
                  'configured': true,
                  'confidence': 0.88,
                  'configPath': '/tmp/opencode',
                  'adapterStatus': 'implemented',
                  'manual': true,
                },
                {
                  'target': 'openclaw',
                  'label': 'OpenClaw',
                  'kind': 'cli',
                  'status': 'not-detected',
                  'configured': false,
                  'confidence': 0.15,
                  'adapterStatus': 'unsupported',
                },
              ],
            }),
            '',
          ),
        );
      },
    );

    final targets = await agentService.scanTargets();

    expect(targets, hasLength(1));
    expect(targets.single.target, 'opencode');
    expect(targets.single.configured, isTrue);
    expect(captured.single, contains('targets scan'));
    expect(
      captured.single,
      contains('--include-accessible-environments false'),
    );
  });

  test(
    'falls back to lico-client in PATH when no binary is discovered',
    () async {
      final captured = <String>[];
      final agentService = AgentService(
        resolveCliBinary: () async => null,
        runCliExecutable: (executable, args, env) {
          captured.add(executable);
          return Future.value(ProcessResult(1, 0, '{"ok":true}', ''));
        },
      );

      await agentService.restoreSnapshot('snapshot-codex-1');
      expect(captured.single, 'lico-client');
      expect(captured.length, 1);
    },
  );

  test('addTarget passes optional manual history root', () async {
    final captured = <List<String>>[];
    final agentService = AgentService(
      runCliExecutable: (executable, args, env) {
        captured.add(List<String>.from(args));
        return Future.value(ProcessResult(0, 0, '{"ok":true}', ''));
      },
    );

    await agentService.addTarget(
      target: 'codex',
      configPath: ' /tmp/codex.toml ',
      binaryPath: ' /usr/local/bin/codex ',
      historyRoot: ' /archives/codex ',
    );

    expect(captured.single, [
      'targets',
      'add',
      '--target',
      'codex',
      '--config-path',
      '/tmp/codex.toml',
      '--binary-path',
      '/usr/local/bin/codex',
      '--history-root',
      '/archives/codex',
    ]);
  });

  test('wraps lico-client execution failure as an exception', () async {
    final agentService = AgentService(
      runCliExecutable: (executable, args, env) {
        return Future.value(ProcessResult(1, 1, '', 'cli failed'));
      },
    );

    await expectLater(
      agentService.planTargetConfig('codex'),
      throwsA(
        isA<Exception>().having(
          (e) => e.toString(),
          'message',
          contains('lico-client failed: cli failed'),
        ),
      ),
    );
  });

  test(
    'builds action command arguments and trims optional parameters',
    () async {
      final captured = <List<String>>[];
      final agentService = AgentService(
        runCliExecutable: (executable, args, env) {
          captured.add(List<String>.from(args));
          return Future.value(
            ProcessResult(
              0,
              0,
              jsonEncode({
                'ok': true,
                'snapshots': [],
                'pairings': [],
                'skills': [],
                'profiles': [],
              }),
              '',
            ),
          );
        },
      );

      await agentService.mcpPluginStatus(
        target: 'codex',
        configPath: ' /tmp/code ',
      );
      await agentService.updateMcpPlugin(target: 'codex');
      await agentService.rollbackMcpPlugin(
        target: 'codex',
        snapshotId: 'snapshot-1',
        configPath: ' /tmp/code ',
      );
      await agentService.listSnapshots(target: 'codex');
      await agentService.listPairings(agent: 'codex');
      await agentService.requestPairing(agent: 'codex', target: 'manual');
      await agentService.approvePairing(agent: 'codex');
      await agentService.revokePairing(agent: 'codex');
      await agentService.listSkills(agent: 'codex');
      await agentService.listModelProfiles();
      await agentService.saveCommandModelProfile(
        profileId: 'local-echo',
        command: 'cat',
      );
      await agentService.forwardText(profileId: 'local-echo', text: 'hello');
      await agentService.localRuntimeStatus();
      await agentService.ensureLocalRuntime(port: 17328, rebuild: true);
      await agentService.startLocalRuntime(port: 17328);
      await agentService.restartLocalRuntime(port: 17328);
      await agentService.stopLocalRuntime();
      await agentService.localRuntimeLogs(tail: 50);

      expect(captured[0], [
        'mcp',
        'plugin',
        'status',
        '--target',
        'codex',
        '--config-path',
        '/tmp/code',
      ]);
      expect(captured[1], ['mcp', 'plugin', 'update', '--target', 'codex']);
      expect(captured[2], [
        'mcp',
        'plugin',
        'rollback',
        '--target',
        'codex',
        '--snapshot-id',
        'snapshot-1',
        '--config-path',
        '/tmp/code',
      ]);
      expect(captured[3], ['snapshots', 'list', '--target', 'codex']);
      expect(captured[4], ['agents', 'pair', 'list', '--agent', 'codex']);
      expect(captured[5], [
        'agents',
        'pair',
        'request',
        '--agent',
        'codex',
        '--target',
        'manual',
      ]);
      expect(captured[6], ['agents', 'pair', 'approve', '--agent', 'codex']);
      expect(captured[7], ['agents', 'pair', 'revoke', '--agent', 'codex']);
      expect(captured[8], ['skill', 'list', '--agent', 'codex']);
      expect(captured[9], ['model', 'profiles', 'list']);
      expect(captured[10], [
        'model',
        'profiles',
        'set',
        'local-echo',
        '--command',
        'cat',
      ]);
      expect(captured[11], [
        'forward',
        '--profile',
        'local-echo',
        '--text',
        'hello',
      ]);
      expect(captured[12], ['local-runtime', 'status']);
      expect(captured[13], [
        'local-runtime',
        'ensure',
        '--port',
        '17328',
        '--rebuild',
        'true',
      ]);
      expect(captured[14], ['local-runtime', 'start', '--port', '17328']);
      expect(captured[15], ['local-runtime', 'restart', '--port', '17328']);
      expect(captured[16], ['local-runtime', 'stop']);
      expect(captured[17], ['local-runtime', 'logs', '--tail', '50']);
    },
  );

  test('returns empty list when list output is invalid', () async {
    final agentService = AgentService(
      runCliExecutable: (executable, args, env) {
        return Future.value(
          ProcessResult(
            0,
            0,
            jsonEncode({'ok': true, 'pairings': 'broken'}),
            '',
          ),
        );
      },
    );

    final pairings = await agentService.listPairings(agent: 'codex');
    expect(pairings, isEmpty);
  });

  test('builds skill install command arguments', () async {
    final captured = <List<String>>[];
    final agentService = AgentService(
      runCliExecutable: (executable, args, env) {
        captured.add(List<String>.from(args));
        return Future.value(ProcessResult(0, 0, '{"ok":true}', ''));
      },
    );

    await agentService.planSkillInstall(
      agent: 'codex',
      url: ' https://github.com/example/skills/tree/main/review ',
      installRoot: ' /tmp/codex-skills ',
      name: ' review-helper ',
      overwrite: true,
    );
    await agentService.applySkillInstall(
      agent: 'codex',
      url: 'https://github.com/example/skills/tree/main/review',
      installRoot: '/tmp/codex-skills',
      name: 'review-helper',
      overwrite: true,
      pin: true,
    );
    await agentService.rollbackSkillInstall(
      agent: 'codex',
      snapshotId: 'skill-install-snapshot-1',
    );

    expect(captured[0], [
      'skill',
      'install',
      'plan',
      '--agent',
      'codex',
      '--url',
      'https://github.com/example/skills/tree/main/review',
      '--install-root',
      '/tmp/codex-skills',
      '--name',
      'review-helper',
      '--overwrite',
      'true',
    ]);
    expect(captured[1], [
      'skill',
      'install',
      'apply',
      '--agent',
      'codex',
      '--url',
      'https://github.com/example/skills/tree/main/review',
      '--install-root',
      '/tmp/codex-skills',
      '--name',
      'review-helper',
      '--overwrite',
      'true',
      '--pin',
      'true',
    ]);
    expect(captured[2], [
      'skill',
      'install',
      'rollback',
      '--agent',
      'codex',
      '--snapshot-id',
      'skill-install-snapshot-1',
    ]);
  });
}
