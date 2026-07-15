import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_client/src/platform/native_client/agent_service.dart';
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
    expect(captured.single, contains('--include-accessible-environments true'));
    expect(captured.single, contains('--include-history-model-catalog true'));
  });

  test('sends private runtime request over stdin instead of argv', () async {
    if (Platform.isWindows) {
      return;
    }
    final tempDir = await Directory.systemTemp.createTemp('lico-cli-stdin-');
    addTearDown(() => tempDir.delete(recursive: true));
    final cliPath = File('${tempDir.path}/lico-client');
    await cliPath.writeAsString('''#!/bin/sh
body=\$(cat)
if [ "\$body" = '{"text":"stdin-canary"}' ]; then
  printf '{"ok":true,"sawStdin":true}'
else
  printf '{"ok":false,"sawStdin":false}'
fi
''');
    final chmod = await Process.run('chmod', ['+x', cliPath.path]);
    expect(chmod.exitCode, 0);
    final agentService = AgentService(resolveCliBinary: () async => cliPath);

    final result = await agentService.runCliWithStdin(const [
      'agent',
      'message',
      'send',
      '--stdin-json',
      'true',
    ], '{"text":"stdin-canary"}');

    expect(result, {'ok': true, 'sawStdin': true});
  });

  test('redacts process start details from private runtime errors', () async {
    final agentService = AgentService(
      resolveCliBinary: () async => File('/private-path-canary/lico-client'),
      startCliExecutable: (executable, args, env) async {
        throw ProcessException(
          executable,
          args,
          'private-process-detail-canary',
        );
      },
    );

    try {
      await agentService.runCliWithStdin(const [
        'agent',
        'message',
        'send',
        '--stdin-json',
        'true',
      ], '{"text":"private-request-canary"}');
      fail('expected the private runtime request to fail');
    } catch (error) {
      final message = error.toString();
      expect(message, contains('lico-client executable could not be started'));
      expect(message, isNot(contains('private-path-canary')));
      expect(message, isNot(contains('private-process-detail-canary')));
      expect(message, isNot(contains('private-request-canary')));
    }
  });

  test('bounds private runtime input before starting the sidecar', () async {
    var started = false;
    final agentService = AgentService(
      startCliExecutable: (executable, args, env) async {
        started = true;
        throw StateError('must not start');
      },
    );

    await expectLater(
      agentService.runCliWithStdin(const [
        'agent',
        'message',
        'send',
        '--stdin-json',
        'true',
      ], List<String>.filled(1024 * 1024 + 1, 'x').join()),
      throwsA(
        predicate((error) => error.toString().contains('request is too large')),
      ),
    );
    expect(started, isFalse);
  });

  test('times out and terminates a stalled private runtime sidecar', () async {
    if (Platform.isWindows) {
      return;
    }
    final tempDir = await Directory.systemTemp.createTemp('lico-cli-timeout-');
    addTearDown(() => tempDir.delete(recursive: true));
    final cliPath = File('${tempDir.path}/lico-client');
    await cliPath.writeAsString('''#!/bin/sh
exec sleep 5
''');
    final chmod = await Process.run('chmod', ['+x', cliPath.path]);
    expect(chmod.exitCode, 0);
    final agentService = AgentService(
      resolveCliBinary: () async => cliPath,
      privateRuntimeTimeout: const Duration(milliseconds: 100),
    );

    await expectLater(
      agentService.runCliWithStdin(const [
        'agent',
        'message',
        'send',
        '--stdin-json',
        'true',
      ], '{"text":"timeout-canary"}'),
      throwsA(
        predicate((error) => error.toString().contains('request timed out')),
      ),
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

  test('injects enabled proxy bridge environment into CLI runs', () async {
    final tempDir = await Directory.systemTemp.createTemp('lico-proxy-env-');
    addTearDown(() => tempDir.delete(recursive: true));
    final clientDir = Directory('${tempDir.path}/lico-client');
    await clientDir.create(recursive: true);
    await File('${clientDir.path}/proxy-bridge.json').writeAsString(
      jsonEncode({
        'enabled': true,
        'clientBridge': {
          'enabled': true,
          'environment': {
            'HTTP_PROXY': 'http://127.0.0.1:7897',
            'HTTPS_PROXY': 'http://127.0.0.1:7897',
            'ALL_PROXY': 'http://127.0.0.1:7897',
            'NO_PROXY': '127.0.0.1,localhost,::1,.local',
          },
        },
      }),
    );
    Map<String, String>? capturedEnv;
    final agentService = AgentService(
      dataDirectory: () async => tempDir.path,
      runCliExecutable: (executable, args, env) {
        capturedEnv = env;
        return Future.value(
          ProcessResult(0, 0, jsonEncode({'ok': true, 'candidates': []}), ''),
        );
      },
    );

    await agentService.scanTargets();

    expect(capturedEnv?['LICO_CLIENT_PORTABLE_DIR'], tempDir.path);
    expect(capturedEnv?['LICO_PORTABLE_DIR'], tempDir.path);
    expect(capturedEnv?['HTTP_PROXY'], 'http://127.0.0.1:7897');
    expect(capturedEnv?['ALL_PROXY'], 'http://127.0.0.1:7897');
    expect(capturedEnv?['NO_PROXY'], contains('localhost'));
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
        isA<Exception>()
            .having(
              (e) => e.toString(),
              'message',
              contains('lico-client command could not be completed'),
            )
            .having(
              (e) => e.toString(),
              'redaction',
              isNot(contains('cli failed')),
            ),
      ),
    );
  });

  test('builds action command arguments and trims optional parameters', () async {
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
    await agentService.localRuntimeStatus();
    await agentService.ensureLocalRuntime(
      sourceRoot: '/repo',
      presetConfig:
          '/repo/packages/foundation/config/composition-presets/client-local-runtime.preset.json',
      port: 17328,
      rebuild: true,
    );
    await agentService.startLocalRuntime(port: 17328);
    await agentService.restartLocalRuntime(port: 17328);
    await agentService.stopLocalRuntime();
    await agentService.localRuntimeLogs(tail: 50);
    await agentService.proxyBridgeDetect();
    await agentService.proxyBridgeStatus();
    await agentService.proxyBridgePlan(targets: 'codex,claude-code');
    await agentService.proxyBridgeApply(targets: 'codex');
    await agentService.proxyBridgeRollback(removeWrappers: false);

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
    expect(captured[9], ['local-runtime', 'status']);
    expect(captured[10], [
      'local-runtime',
      'ensure',
      '--source-root',
      '/repo',
      '--preset-config',
      '/repo/packages/foundation/config/composition-presets/client-local-runtime.preset.json',
      '--port',
      '17328',
      '--rebuild',
      'true',
    ]);
    expect(captured[11], ['local-runtime', 'start', '--port', '17328']);
    expect(captured[12], ['local-runtime', 'restart', '--port', '17328']);
    expect(captured[13], ['local-runtime', 'stop']);
    expect(captured[14], ['local-runtime', 'logs', '--tail', '50']);
    expect(captured[15], ['proxy-bridge', 'detect']);
    expect(captured[16], ['proxy-bridge', 'status']);
    expect(captured[17], [
      'proxy-bridge',
      'plan',
      '--client-enabled',
      'true',
      '--wrapper-enabled',
      'true',
      '--targets',
      'codex,claude-code',
    ]);
    expect(captured[18], [
      'proxy-bridge',
      'apply',
      '--client-enabled',
      'true',
      '--wrapper-enabled',
      'true',
      '--targets',
      'codex',
    ]);
    expect(captured[19], [
      'proxy-bridge',
      'rollback',
      '--remove-wrappers',
      'false',
    ]);
  });

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

  test(
    'macOS runCli lazily reuses one serialized stdio RPC workflow',
    () async {
      if (!Platform.isMacOS) {
        return;
      }
      final tempDir = await Directory.systemTemp.createTemp('lico-rpc-reuse-');
      addTearDown(() => tempDir.delete(recursive: true));
      final cli = File('${tempDir.path}/lico-client');
      final marker = File('${tempDir.path}/rpc-events.log');
      await _writeExecutable(cli, r'''#!/bin/sh
dir=$(CDPATH= cd "$(dirname "$0")" && pwd)
marker="$dir/rpc-events.log"
printf 'started\n' >> "$marker"
sequence=0
while IFS= read -r line; do
  id=$(printf '%s\n' "$line" | sed -E 's/.*"id":"([^"]+)".*/\1/')
  workflow=$(printf '%s\n' "$line" | sed -E 's/.*"workflowId":"([^"]+)".*/\1/')
  case "$line" in
    *'"method":"shutdown"'*)
      printf 'shutdown:%s\n' "$workflow" >> "$marker"
      printf '{"protocol":"lico-client.stdio.v1","id":"%s","workflowId":"%s","ok":true,"result":{"status":"shutdown"}}\n' "$id" "$workflow"
      exit 0
      ;;
  esac
  sequence=$((sequence + 1))
  printf 'execute:%s:%s\n' "$sequence" "$workflow" >> "$marker"
  if [ "$sequence" -eq 1 ]; then
    sleep 0.1
  fi
  printf '{"protocol":"lico-client.stdio.v1","id":"%s","workflowId":"%s","ok":true,"result":{"ok":true,"sequence":%s,"workflow":"%s"}}\n' "$id" "$workflow" "$sequence" "$workflow"
done
''');
      final service = AgentService(resolveCliBinary: () async => cli);
      addTearDown(service.dispose);

      expect(await marker.exists(), isFalse);
      final responses = await Future.wait([
        service.runCli(const ['state', 'get', 'settings']),
        service.runCli(const ['state', 'get', 'targets']),
      ]);

      expect(responses[0]['sequence'], 1);
      expect(responses[1]['sequence'], 2);
      expect(responses[0]['workflow'], responses[1]['workflow']);
      await service.dispose();
      await service.dispose();

      final events = await marker.readAsLines();
      expect(events.where((event) => event == 'started'), hasLength(1));
      expect(
        events.where((event) => event.startsWith('execute:')),
        hasLength(2),
      );
      expect(
        events.where((event) => event.startsWith('shutdown:')),
        hasLength(1),
      );
    },
  );

  test(
    'macOS stdio RPC preserves authorization_required classification',
    () async {
      if (!Platform.isMacOS) {
        return;
      }
      final tempDir = await Directory.systemTemp.createTemp('lico-rpc-auth-');
      addTearDown(() => tempDir.delete(recursive: true));
      final cli = File('${tempDir.path}/lico-client');
      await _writeExecutable(cli, r'''#!/bin/sh
while IFS= read -r line; do
  id=$(printf '%s\n' "$line" | sed -E 's/.*"id":"([^"]+)".*/\1/')
  workflow=$(printf '%s\n' "$line" | sed -E 's/.*"workflowId":"([^"]+)".*/\1/')
  case "$line" in
    *'"method":"shutdown"'*)
      printf '{"protocol":"lico-client.stdio.v1","id":"%s","workflowId":"%s","ok":true,"result":{"status":"shutdown"}}\n' "$id" "$workflow"
      exit 0
      ;;
  esac
  printf '{"protocol":"lico-client.stdio.v1","id":"%s","workflowId":"%s","ok":false,"error":{"code":"authorization_required","message":"private-error-canary"}}\n' "$id" "$workflow"
done
''');
      final service = AgentService(resolveCliBinary: () async => cli);
      addTearDown(service.dispose);

      Object? caught;
      try {
        await service.runCli(const ['mobile', 'relay', 'commands', 'sync']);
      } on Object catch (error) {
        caught = error;
      }

      expect(caught, isA<LicoClientRpcException>());
      final rpcError = caught! as LicoClientRpcException;
      expect(rpcError.code, 'authorization_required');
      expect(rpcError.authorizationRequired, isTrue);
      expect(rpcError.toString(), isNot(contains('private-error-canary')));
    },
  );

  test(
    'macOS conversation streaming reuses one persistent RPC process',
    () async {
      if (!Platform.isMacOS) {
        return;
      }
      final tempDir = await Directory.systemTemp.createTemp('lico-rpc-stream-');
      addTearDown(() => tempDir.delete(recursive: true));
      final cli = File('${tempDir.path}/lico-client');
      final marker = File('${tempDir.path}/rpc-events.log');
      await _writeExecutable(cli, r'''#!/bin/sh
dir=$(CDPATH= cd "$(dirname "$0")" && pwd)
marker="$dir/rpc-events.log"
printf 'started\n' >> "$marker"
turn=0
while IFS= read -r line; do
  id=$(printf '%s\n' "$line" | sed -E 's/.*"id":"([^"]+)".*/\1/')
  workflow=$(printf '%s\n' "$line" | sed -E 's/.*"workflowId":"([^"]+)".*/\1/')
  case "$line" in
    *'"method":"shutdown"'*)
      printf '{"protocol":"lico-client.stdio.v1","id":"%s","workflowId":"%s","ok":true,"result":{"status":"shutdown"}}\n' "$id" "$workflow"
      exit 0
      ;;
  esac
  turn=$((turn + 1))
  printf 'send:%s:%s\n' "$turn" "$workflow" >> "$marker"
  printf '{"protocol":"lico-client.stdio.v1","id":"%s","workflowId":"%s","kind":"event","sequence":1,"event":{"event":"agent.message.chunk","sessionId":"native-session","turnId":"turn-%s","payload":{"text":"chunk-%s"}}}\n' "$id" "$workflow" "$turn" "$turn"
  printf '{"protocol":"lico-client.stdio.v1","id":"%s","workflowId":"%s","kind":"terminal","sequence":2,"ok":true,"result":{"ok":true,"nativeSessionId":"native-session","sessionId":"native-session","turnId":"turn-%s","turnStatus":"completed"}}\n' "$id" "$workflow" "$turn"
done
''');
      final service = AgentService(resolveCliBinary: () async => cli);
      addTearDown(service.dispose);
      const args = [
        'agent',
        'conversation',
        'send',
        '--stdin-json',
        'true',
        '--stream-events',
        'true',
      ];

      final first = await service
          .streamCliJsonLinesWithStdin(
            args,
            '{"agent":"claude-code","text":"one","streamEvents":true}',
          )
          .toList();
      final second = await service
          .streamCliJsonLinesWithStdin(
            args,
            '{"agent":"claude-code","text":"two","sessionId":"native-session","streamEvents":true}',
          )
          .toList();

      expect(first.map((event) => event['event']), [
        'agent.message.chunk',
        'done',
      ]);
      expect(second.map((event) => event['event']), [
        'agent.message.chunk',
        'done',
      ]);
      expect(first.last['nativeSessionId'], 'native-session');
      expect(second.last['turnId'], 'turn-2');
      await service.dispose();
      final events = await marker.readAsLines();
      expect(events.where((event) => event == 'started'), hasLength(1));
      expect(events.where((event) => event.startsWith('send:')), hasLength(2));
      expect(
        events
            .where((event) => event.startsWith('send:'))
            .map((event) => event.split(':').last),
        everyElement(equals(events[1].split(':').last)),
      );
    },
  );

  test('macOS conversation RPC fails closed on out-of-order frames', () async {
    if (!Platform.isMacOS) {
      return;
    }
    final tempDir = await Directory.systemTemp.createTemp('lico-rpc-order-');
    addTearDown(() => tempDir.delete(recursive: true));
    final cli = File('${tempDir.path}/lico-client');
    await _writeExecutable(cli, r'''#!/bin/sh
while IFS= read -r line; do
  id=$(printf '%s\n' "$line" | sed -E 's/.*"id":"([^"]+)".*/\1/')
  workflow=$(printf '%s\n' "$line" | sed -E 's/.*"workflowId":"([^"]+)".*/\1/')
  printf '{"protocol":"lico-client.stdio.v1","id":"%s","workflowId":"%s","kind":"event","sequence":2,"event":{"event":"agent.message.chunk","sessionId":"native-session","turnId":"turn-1","payload":{"text":"invalid"}}}\n' "$id" "$workflow"
done
''');
    final service = AgentService(resolveCliBinary: () async => cli);
    addTearDown(service.dispose);

    await expectLater(
      service.streamCliJsonLinesWithStdin(const [
        'agent',
        'conversation',
        'send',
      ], '{"agent":"claude-code","text":"one"}').toList(),
      throwsA(
        isA<LicoClientRpcException>().having(
          (error) => error.code,
          'code',
          'invalid_response',
        ),
      ),
    );
  });

  test(
    'macOS conversation RPC rejects duplicate terminal before reuse',
    () async {
      if (!Platform.isMacOS) {
        return;
      }
      final tempDir = await Directory.systemTemp.createTemp(
        'lico-rpc-terminal-',
      );
      addTearDown(() => tempDir.delete(recursive: true));
      final cli = File('${tempDir.path}/lico-client');
      final marker = File('${tempDir.path}/rpc-events.log');
      await _writeExecutable(cli, r'''#!/bin/sh
dir=$(CDPATH= cd "$(dirname "$0")" && pwd)
marker="$dir/rpc-events.log"
printf 'started\n' >> "$marker"
while IFS= read -r line; do
  id=$(printf '%s\n' "$line" | sed -E 's/.*"id":"([^"]+)".*/\1/')
  workflow=$(printf '%s\n' "$line" | sed -E 's/.*"workflowId":"([^"]+)".*/\1/')
  case "$line" in
    *'"method":"shutdown"'*) exit 0 ;;
  esac
  printf '{"protocol":"lico-client.stdio.v1","id":"%s","workflowId":"%s","kind":"terminal","sequence":1,"ok":true,"result":{"ok":true,"nativeSessionId":"native-session","turnId":"turn-1"}}\n' "$id" "$workflow"
  printf '{"protocol":"lico-client.stdio.v1","id":"%s","workflowId":"%s","kind":"terminal","sequence":2,"ok":true,"result":{"ok":true,"nativeSessionId":"native-session","turnId":"turn-duplicate"}}\n' "$id" "$workflow"
done
''');
      final service = AgentService(resolveCliBinary: () async => cli);
      addTearDown(service.dispose);

      final result = await service.streamCliJsonLinesWithStdin(const [
        'agent',
        'conversation',
        'send',
      ], '{"agent":"claude-code","text":"one"}').toList();
      expect(result, hasLength(1));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await service.runCli(const ['state', 'get', 'settings']);

      final events = await marker.readAsLines();
      expect(events.where((event) => event == 'started'), hasLength(2));
    },
  );

  test(
    'macOS conversation RPC fails closed on oversized event frame',
    () async {
      if (!Platform.isMacOS) {
        return;
      }
      final tempDir = await Directory.systemTemp.createTemp('lico-rpc-output-');
      addTearDown(() => tempDir.delete(recursive: true));
      final cli = File('${tempDir.path}/lico-client');
      await _writeExecutable(cli, r'''#!/bin/sh
if IFS= read -r line; then
  head -c 16777216 /dev/zero | tr '\000' x
  printf '\n'
fi
''');
      final service = AgentService(resolveCliBinary: () async => cli);
      addTearDown(service.dispose);

      await expectLater(
        service.streamCliJsonLinesWithStdin(const [
          'agent',
          'conversation',
          'send',
        ], '{"agent":"claude-code","text":"one"}').toList(),
        throwsA(
          isA<LicoClientRpcException>().having(
            (error) => error.code,
            'code',
            'transport_failed',
          ),
        ),
      );
    },
  );

  test('macOS stdio RPC redacts setup failures', () async {
    if (!Platform.isMacOS) {
      return;
    }
    final service = AgentService(
      dataDirectory: () async {
        throw StateError('private-setup-canary');
      },
      resolveCliBinary: () async => File('/private-binary-canary/lico-client'),
    );
    addTearDown(service.dispose);

    Object? caught;
    try {
      await service.runCli(const ['state', 'get', 'settings']);
    } on Object catch (error) {
      caught = error;
    }

    expect(caught, isA<LicoClientRpcException>());
    final rpcError = caught! as LicoClientRpcException;
    expect(rpcError.code, 'setup_failed');
    expect(rpcError.toString(), isNot(contains('private-setup-canary')));
    expect(rpcError.toString(), isNot(contains('private-binary-canary')));
  });

  test('macOS stdio RPC never retries a request after writing it', () async {
    if (!Platform.isMacOS) {
      return;
    }
    final tempDir = await Directory.systemTemp.createTemp('lico-rpc-once-');
    addTearDown(() => tempDir.delete(recursive: true));
    final cli = File('${tempDir.path}/lico-client');
    final marker = File('${tempDir.path}/rpc-events.log');
    await _writeExecutable(cli, r'''#!/bin/sh
dir=$(CDPATH= cd "$(dirname "$0")" && pwd)
marker="$dir/rpc-events.log"
printf 'started\n' >> "$marker"
if IFS= read -r line; then
  printf 'received\n' >> "$marker"
fi
exit 0
''');
    final service = AgentService(resolveCliBinary: () async => cli);
    addTearDown(service.dispose);

    await expectLater(
      service.runCli(const ['state', 'set', 'settings', '{}']),
      throwsA(
        isA<LicoClientRpcException>().having(
          (error) => error.code,
          'code',
          'transport_failed',
        ),
      ),
    );

    final events = await marker.readAsLines();
    expect(events.where((event) => event == 'started'), hasLength(1));
    expect(events.where((event) => event == 'received'), hasLength(1));
  });

  test('macOS stdio RPC rejects oversized args before process start', () async {
    if (!Platform.isMacOS) {
      return;
    }
    final tempDir = await Directory.systemTemp.createTemp('lico-rpc-input-');
    addTearDown(() => tempDir.delete(recursive: true));
    final cli = File('${tempDir.path}/lico-client');
    final marker = File('${tempDir.path}/started');
    await _writeExecutable(cli, r'''#!/bin/sh
dir=$(CDPATH= cd "$(dirname "$0")" && pwd)
touch "$dir/started"
exit 0
''');
    final service = AgentService(resolveCliBinary: () async => cli);
    addTearDown(service.dispose);
    final oversizedArg = String.fromCharCodes(
      Uint8List(1024 * 1024 + 1)..fillRange(0, 1024 * 1024 + 1, 0x78),
    );

    await expectLater(
      service.runCli(['state', 'set', 'settings', oversizedArg]),
      throwsA(
        isA<LicoClientRpcException>().having(
          (error) => error.code,
          'code',
          'invalid_request',
        ),
      ),
    );

    expect(await marker.exists(), isFalse);
  });

  test('macOS stdio RPC timeout terminates the persistent process', () async {
    if (!Platform.isMacOS) {
      return;
    }
    final tempDir = await Directory.systemTemp.createTemp('lico-rpc-timeout-');
    addTearDown(() => tempDir.delete(recursive: true));
    final cli = File('${tempDir.path}/lico-client');
    await _writeExecutable(cli, r'''#!/bin/sh
if IFS= read -r line; then
  exec sleep 5
fi
''');
    final service = AgentService(
      resolveCliBinary: () async => cli,
      privateRuntimeTimeout: const Duration(milliseconds: 100),
    );
    addTearDown(service.dispose);

    await expectLater(
      service.runCli(const ['state', 'get', 'settings']),
      throwsA(
        isA<LicoClientRpcException>().having(
          (error) => error.code,
          'code',
          'timeout',
        ),
      ),
    );
  });
}

Future<void> _writeExecutable(File file, String source) async {
  await file.writeAsString(source);
  final chmod = await Process.run('chmod', ['+x', file.path]);
  expect(chmod.exitCode, 0);
}
