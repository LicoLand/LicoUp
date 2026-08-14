import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:licoup/src/platform/native_client/agent_service.dart';
import 'package:licoup/src/platform/native_client/native_cli_ports.dart';
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
      'detail': 'OpenCode local agent configuration',
      'configPath': 'test-data/opencode.jsonc',
      'binaryPath': 'test-binary-opencode',
      'historyRoots': ['test-data/opencode-history'],
      'adapterStatus': 'skeleton',
      'manual': true,
    });

    expect(target.target, 'opencode');
    expect(target.label, 'OpenCode');
    expect(target.configured, isFalse);
    expect(target.configPath, 'test-data/opencode.jsonc');
    expect(target.binaryPath, 'test-binary-opencode');
    expect(target.historyRoots, ['test-data/opencode-history']);
    expect(target.adapterStatus, 'skeleton');
    expect(target.manual, isTrue);
  });

  test('uses injected binary path in CLI execution', () async {
    final tempDir = await Directory.systemTemp.createTemp('lico-cli-binary-');
    addTearDown(() => tempDir.delete(recursive: true));
    final cliPath = File('${tempDir.path}/licoup');
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
                  'configPath': 'test-data/opencode',
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
    final cliPath = File('${tempDir.path}/licoup');
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

  test(
    'catalog snapshots use structured RPC without catalog bytes in argv',
    () async {
      final transport = _RecordingStructuredTransport();
      final agentService = AgentService(
        stdioRpcTransport: transport,
        persistentStdioRpcEnabled: true,
      );
      addTearDown(agentService.dispose);

      final result = await agentService.runCatalogCommand(
        'refresh',
        params: const {
          'partitionKey': 'opaque-a',
          'tools': [
            {'name': 'upstream.synthetic'},
          ],
        },
      );

      expect(result['outcome'], 'replaced');
      expect(transport.method, 'catalog.refresh');
      expect(transport.params['tools'], hasLength(1));
      expect(transport.executeCalls, isEmpty);
    },
  );

  test('redacts process start details from private runtime errors', () async {
    final agentService = AgentService(
      resolveCliBinary: () async => File('/private-path-canary/licoup'),
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
      expect(message, contains('licoup executable could not be started'));
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
    final cliPath = File('${tempDir.path}/licoup');
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
    'falls back to licoup-cli in PATH when no binary is discovered',
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
      expect(captured.single, 'licoup-cli');
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
      configPath: ' test-data/codex.toml ',
      binaryPath: ' test-binary-codex ',
      historyRoot: ' /archives/codex ',
    );

    expect(captured.single, [
      'targets',
      'add',
      '--target',
      'codex',
      '--config-path',
      'test-data/codex.toml',
      '--binary-path',
      'test-binary-codex',
      '--history-root',
      '/archives/codex',
    ]);
  });

  test('wraps licoup execution failure as an exception', () async {
    final agentService = AgentService(
      runCliExecutable: (executable, args, env) {
        return Future.value(ProcessResult(1, 1, '', 'cli failed'));
      },
    );

    await expectLater(
      agentService.inspectTarget('codex'),
      throwsA(
        isA<Exception>()
            .having(
              (e) => e.toString(),
              'message',
              contains('licoup command could not be completed'),
            )
            .having(
              (e) => e.toString(),
              'redaction',
              isNot(contains('cli failed')),
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

      await agentService.listSnapshots(target: 'codex');
      await agentService.listPairings(agent: 'codex');
      await agentService.requestPairing(agent: 'codex', target: 'manual');
      await agentService.approvePairing(agent: 'codex');
      await agentService.revokePairing(agent: 'codex');
      await agentService.listSkills(agent: 'codex');
      expect(captured[0], ['snapshots', 'list', '--target', 'codex']);
      expect(captured[1], ['agents', 'pair', 'list', '--agent', 'codex']);
      expect(captured[2], [
        'agents',
        'pair',
        'request',
        '--agent',
        'codex',
        '--target',
        'manual',
      ]);
      expect(captured[3], ['agents', 'pair', 'approve', '--agent', 'codex']);
      expect(captured[4], ['agents', 'pair', 'revoke', '--agent', 'codex']);
      expect(captured[5], ['skill', 'list', '--agent', 'codex']);
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

  test(
    'macOS runCli lazily reuses one serialized stdio RPC workflow',
    () async {
      if (!Platform.isMacOS) {
        return;
      }
      final tempDir = await Directory.systemTemp.createTemp('lico-rpc-reuse-');
      addTearDown(() => tempDir.delete(recursive: true));
      final cli = File('${tempDir.path}/licoup');
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
      printf '{"protocol":"licoup.stdio.v1","id":"%s","workflowId":"%s","ok":true,"result":{"status":"shutdown"}}\n' "$id" "$workflow"
      exit 0
      ;;
  esac
  sequence=$((sequence + 1))
  printf 'execute:%s:%s\n' "$sequence" "$workflow" >> "$marker"
  if [ "$sequence" -eq 1 ]; then
    sleep 0.1
  fi
  printf '{"protocol":"licoup.stdio.v1","id":"%s","workflowId":"%s","ok":true,"result":{"ok":true,"sequence":%s,"workflow":"%s"}}\n' "$id" "$workflow" "$sequence" "$workflow"
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
      final cli = File('${tempDir.path}/licoup');
      await _writeExecutable(cli, r'''#!/bin/sh
while IFS= read -r line; do
  id=$(printf '%s\n' "$line" | sed -E 's/.*"id":"([^"]+)".*/\1/')
  workflow=$(printf '%s\n' "$line" | sed -E 's/.*"workflowId":"([^"]+)".*/\1/')
  case "$line" in
    *'"method":"shutdown"'*)
      printf '{"protocol":"licoup.stdio.v1","id":"%s","workflowId":"%s","ok":true,"result":{"status":"shutdown"}}\n' "$id" "$workflow"
      exit 0
      ;;
  esac
  printf '{"protocol":"licoup.stdio.v1","id":"%s","workflowId":"%s","ok":false,"error":{"code":"authorization_required","message":"private-error-canary"}}\n' "$id" "$workflow"
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
      final cli = File('${tempDir.path}/licoup');
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
      printf '{"protocol":"licoup.stdio.v1","id":"%s","workflowId":"%s","ok":true,"result":{"status":"shutdown"}}\n' "$id" "$workflow"
      exit 0
      ;;
  esac
  turn=$((turn + 1))
  printf 'send:%s:%s\n' "$turn" "$workflow" >> "$marker"
  printf '{"protocol":"licoup.stdio.v1","id":"%s","workflowId":"%s","kind":"event","sequence":1,"event":{"event":"agent.message.chunk","sessionId":"native-session","turnId":"turn-%s","payload":{"text":"chunk-%s"}}}\n' "$id" "$workflow" "$turn" "$turn"
  printf '{"protocol":"licoup.stdio.v1","id":"%s","workflowId":"%s","kind":"terminal","sequence":2,"ok":true,"result":{"ok":true,"nativeSessionId":"native-session","sessionId":"native-session","turnId":"turn-%s","turnStatus":"completed"}}\n' "$id" "$workflow" "$turn"
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

  test(
    'macOS conversation send is isolated from non-dispatch stdio RPC',
    () async {
      if (!Platform.isMacOS) {
        return;
      }
      final tempDir = await Directory.systemTemp.createTemp(
        'lico-rpc-process-local-',
      );
      addTearDown(() => tempDir.delete(recursive: true));
      final cli = File('${tempDir.path}/licoup');
      final marker = File('${tempDir.path}/rpc-events.log');
      await _writeExecutable(cli, r'''#!/bin/sh
dir=$(CDPATH= cd "$(dirname "$0")" && pwd)
marker="$dir/rpc-events.log"
lane="$*"
printf 'started:%s\n' "$lane" >> "$marker"
while IFS= read -r line; do
  id=$(printf '%s\n' "$line" | sed -E 's/.*"id":"([^"]+)".*/\1/')
  workflow=$(printf '%s\n' "$line" | sed -E 's/.*"workflowId":"([^"]+)".*/\1/')
  case "$line" in
    *'"method":"shutdown"'*)
      printf 'shutdown:%s:%s\n' "$lane" "$workflow" >> "$marker"
      printf '{"protocol":"licoup.stdio.v1","id":"%s","workflowId":"%s","ok":true,"result":{"status":"shutdown"}}\n' "$id" "$workflow"
      exit 0
      ;;
    *'"method":"agent.conversation.send"'*)
      printf 'send:%s:%s\n' "$lane" "$workflow" >> "$marker"
      printf '{"protocol":"licoup.stdio.v1","id":"%s","workflowId":"%s","kind":"event","sequence":1,"event":{"event":"agent.message.chunk","sessionId":"native-session","turnId":"turn-1","payload":{"text":"chunk"}}}\n' "$id" "$workflow"
      printf '{"protocol":"licoup.stdio.v1","id":"%s","workflowId":"%s","kind":"terminal","sequence":2,"ok":true,"result":{"ok":true,"nativeSessionId":"native-session","sessionId":"native-session","turnId":"turn-1","turnStatus":"completed"}}\n' "$id" "$workflow"
      ;;
    *'"method":"agent.conversation.open"'*) operation=open ;;
    *'"method":"agent.conversation.history"'*) operation=history ;;
    *'"method":"agent.conversation.cleanup"'*) operation=cleanup ;;
    *'"method":"agent.conversation.capabilities"'*) operation=capabilities ;;
    *) operation=unexpected ;;
  esac
  if [ "${operation:-}" != "" ]; then
    printf '%s:%s:%s\n' "$operation" "$lane" "$workflow" >> "$marker"
    printf '{"protocol":"licoup.stdio.v1","id":"%s","workflowId":"%s","ok":true,"result":{"ok":true,"operation":"%s"}}\n' "$id" "$workflow" "$operation"
    operation=
  fi
done
''');
      final service = AgentService(resolveCliBinary: () async => cli);
      addTearDown(service.dispose);
      for (final operation in const ['open', 'capabilities', 'history']) {
        final result = await service.runCliWithStdin([
          'agent',
          'conversation',
          operation,
          '--stdin-json',
          'true',
        ], '{"agent":"claude-code","sessionId":"native-session"}');
        expect(result['operation'], operation);
      }
      final streamed = await service.streamCliJsonLinesWithStdin(
        const [
          'agent',
          'conversation',
          'send',
          '--stdin-json',
          'true',
          '--stream-events',
          'true',
        ],
        '{"agent":"claude-code","sessionId":"native-session","text":"bounded"}',
      ).toList();
      expect(streamed.map((event) => event['event']), [
        'agent.message.chunk',
        'done',
      ]);
      final cleanup = await service.runCliWithStdin(const [
        'agent',
        'conversation',
        'cleanup',
        '--stdin-json',
        'true',
      ], '{"agent":"claude-code","sessionId":"native-session"}');
      expect(cleanup['operation'], 'cleanup');
      await service.dispose();

      final rows = await marker.readAsLines();
      expect(rows.where((row) => row.startsWith('started:')), [
        'started:rpc stdio',
        'started:rpc conversation',
      ]);
      final operations = rows
          .where(
            (row) =>
                !row.startsWith('started:') && !row.startsWith('shutdown:'),
          )
          .toList();
      expect(operations.map((row) => row.split(':').first), [
        'open',
        'capabilities',
        'history',
        'send',
        'cleanup',
      ]);
      expect(operations.map((row) => row.split(':')[1]), [
        'rpc stdio',
        'rpc stdio',
        'rpc stdio',
        'rpc conversation',
        'rpc stdio',
      ]);
      expect(
        operations.map((row) => row.split(':').last).toSet(),
        hasLength(1),
      );
      expect(
        rows
            .where((row) => row.startsWith('shutdown:'))
            .map((row) => row.split(':')[1]),
        ['rpc stdio'],
      );
    },
  );

  test('macOS conversation RPC fails closed on out-of-order frames', () async {
    if (!Platform.isMacOS) {
      return;
    }
    final tempDir = await Directory.systemTemp.createTemp('lico-rpc-order-');
    addTearDown(() => tempDir.delete(recursive: true));
    final cli = File('${tempDir.path}/licoup');
    await _writeExecutable(cli, r'''#!/bin/sh
while IFS= read -r line; do
  id=$(printf '%s\n' "$line" | sed -E 's/.*"id":"([^"]+)".*/\1/')
  workflow=$(printf '%s\n' "$line" | sed -E 's/.*"workflowId":"([^"]+)".*/\1/')
  printf '{"protocol":"licoup.stdio.v1","id":"%s","workflowId":"%s","kind":"event","sequence":2,"event":{"event":"agent.message.chunk","sessionId":"native-session","turnId":"turn-1","payload":{"text":"invalid"}}}\n' "$id" "$workflow"
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
      final cli = File('${tempDir.path}/licoup');
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
  printf '{"protocol":"licoup.stdio.v1","id":"%s","workflowId":"%s","kind":"terminal","sequence":1,"ok":true,"result":{"ok":true,"nativeSessionId":"native-session","turnId":"turn-1"}}\n' "$id" "$workflow"
  printf '{"protocol":"licoup.stdio.v1","id":"%s","workflowId":"%s","kind":"terminal","sequence":2,"ok":true,"result":{"ok":true,"nativeSessionId":"native-session","turnId":"turn-duplicate"}}\n' "$id" "$workflow"
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
      final cli = File('${tempDir.path}/licoup');
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
      resolveCliBinary: () async => File('/private-binary-canary/licoup'),
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
    final cli = File('${tempDir.path}/licoup');
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
    final cli = File('${tempDir.path}/licoup');
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
    final cli = File('${tempDir.path}/licoup');
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

final class _RecordingStructuredTransport implements NativeStdioRpcTransport {
  String method = '';
  Map<String, dynamic> params = const {};
  final List<List<String>> executeCalls = [];

  @override
  Future<void> dispose() async {}

  @override
  Future<Map<String, dynamic>> execute(List<String> arguments) async {
    executeCalls.add(List<String>.from(arguments));
    return {'ok': true};
  }

  @override
  Future<Map<String, dynamic>> executeStructured(
    String method,
    Map<String, dynamic> params,
  ) async {
    this.method = method;
    this.params = Map<String, dynamic>.from(params);
    return {'outcome': 'replaced'};
  }

  @override
  Stream<Map<String, dynamic>> streamConversation(
    Map<String, dynamic> request,
  ) => const Stream.empty();
}

Future<void> _writeExecutable(File file, String source) async {
  await file.writeAsString(source);
  final chmod = await Process.run('chmod', ['+x', file.path]);
  expect(chmod.exitCode, 0);
}
