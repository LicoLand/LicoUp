import 'dart:async';
import 'dart:io';

import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc.dart';
import 'package:licoup/src/platform/native_client/native_cli_ports.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'stdio RPC rejects invalid arguments before resolving a process',
    () async {
      final context = _FakeProcessContext();
      final client = NativeStdioRpcClient(processContext: context);
      addTearDown(client.dispose);

      await expectLater(
        client.execute(const []),
        throwsA(
          isA<LicoClientRpcException>().having(
            (error) => error.code,
            'code',
            'invalid_request',
          ),
        ),
      );
      expect(context.resolveCount, 0);
      expect(context.startCount, 0);
    },
  );

  test('stdio RPC redacts process setup failures', () async {
    final context = _FakeProcessContext(failSetup: true);
    final client = NativeStdioRpcClient(processContext: context);
    addTearDown(client.dispose);

    Object? caught;
    try {
      await client.execute(const ['state', 'get']);
    } on Object catch (error) {
      caught = error;
    }

    expect(caught, isA<LicoClientRpcException>());
    expect((caught! as LicoClientRpcException).code, 'setup_failed');
    expect(caught.toString(), isNot(contains('setup-detail')));
    expect(context.startCount, 0);
  });

  test(
    'conversation lane is not blocked by a pending command lane request',
    () async {
      if (Platform.isWindows) return;
      final directory = await Directory.systemTemp.createTemp(
        'lico-stdio-lanes-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final executable = File('${directory.path}/licoup');
      await executable.writeAsString(r'''#!/bin/sh
while IFS= read -r line; do
  request_id=$(printf '%s' "$line" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
  workflow_id=$(printf '%s' "$line" | sed -n 's/.*"workflowId":"\([^"]*\)".*/\1/p')
  case "$line" in
    *'"method":"agent.conversation.send"'*)
      printf '{"protocol":"licoup.stdio.v1","id":"%s","workflowId":"%s","kind":"terminal","sequence":1,"ok":true,"result":{"sessionId":"session-1","turnId":"turn-1"}}\n' "$request_id" "$workflow_id"
      ;;
    *'"method":"shutdown"'*)
      printf '{"protocol":"licoup.stdio.v1","id":"%s","workflowId":"%s","ok":true,"result":{}}\n' "$request_id" "$workflow_id"
      exit 0
      ;;
    *)
      sleep 2
      printf '{"protocol":"licoup.stdio.v1","id":"%s","workflowId":"%s","ok":true,"result":{}}\n' "$request_id" "$workflow_id"
      ;;
  esac
done
''');
      final chmod = await Process.run('chmod', ['+x', executable.path]);
      expect(chmod.exitCode, 0);
      final context = _LiveProcessContext(executable);
      final client = NativeStdioRpcClient(processContext: context);
      addTearDown(client.dispose);

      final pendingCommand = client.execute(const ['slow-command']);
      await _waitUntil(() => context.startCount == 1);
      final conversation = await client
          .streamConversation(const {'agent': 'claude-code', 'text': 'probe'})
          .toList()
          .timeout(const Duration(seconds: 1));

      expect(context.startCount, 2);
      expect(conversation.last['event'], 'done');
      await pendingCommand;
    },
  );

  test(
    'in-flight control is multiplexed onto the active conversation lane',
    () async {
      if (Platform.isWindows) return;
      final directory = await Directory.systemTemp.createTemp(
        'lico-stdio-control-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final executable = File('${directory.path}/licoup');
      await executable.writeAsString(r'''#!/bin/sh
send_id=
send_workflow=
while IFS= read -r line; do
  request_id=$(printf '%s' "$line" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
  workflow_id=$(printf '%s' "$line" | sed -n 's/.*"workflowId":"\([^"]*\)".*/\1/p')
  case "$line" in
    *'"method":"agent.conversation.send"'*)
      send_id=$request_id
      send_workflow=$workflow_id
      printf '{"protocol":"licoup.stdio.v1","id":"%s","workflowId":"%s","kind":"event","sequence":1,"event":{"event":"agent.message.chunk","sessionId":"session-1","turnId":"turn-1","payload":{"text":"working"}}}\n' "$send_id" "$send_workflow"
      ;;
    *'"method":"agent.conversation.steer"'*)
      printf '{"protocol":"licoup.stdio.v1","id":"%s","workflowId":"%s","kind":"terminal","sequence":1,"ok":true,"result":{"ok":true,"status":"accepted"}}\n' "$request_id" "$workflow_id"
      printf '{"protocol":"licoup.stdio.v1","id":"%s","workflowId":"%s","kind":"terminal","sequence":2,"ok":true,"result":{"ok":true,"sessionId":"session-1","turnId":"turn-1"}}\n' "$send_id" "$send_workflow"
      ;;
    *'"method":"shutdown"'*)
      printf '{"protocol":"licoup.stdio.v1","id":"%s","workflowId":"%s","ok":true,"result":{}}\n' "$request_id" "$workflow_id"
      exit 0
      ;;
  esac
done
''');
      final chmod = await Process.run('chmod', ['+x', executable.path]);
      expect(chmod.exitCode, 0);
      final context = _LiveProcessContext(executable);
      final client = NativeStdioRpcClient(processContext: context);
      addTearDown(client.dispose);

      final events = <Map<String, dynamic>>[];
      final completed = Completer<void>();
      client
          .streamConversation(const {'agent': 'codex', 'text': 'probe'})
          .listen(events.add, onDone: completed.complete);
      await _waitUntil(() => events.isNotEmpty);

      final steer = await client
          .executeStructured('agent.conversation.steer', const {
            'agent': 'codex',
            'text': 'new guidance',
            'sessionId': 'session-1',
            'turnId': 'turn-1',
          });
      await completed.future.timeout(const Duration(seconds: 1));

      expect(steer['ok'], isTrue);
      expect(events.last['event'], 'done');
      expect(context.startCount, 1);
    },
  );
}

Future<void> _waitUntil(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('condition not reached');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

class _FakeProcessContext implements NativeCliProcessContext {
  _FakeProcessContext({this.failSetup = false});

  final bool failSetup;
  var resolveCount = 0;
  var startCount = 0;

  @override
  Duration get requestTimeout => const Duration(seconds: 1);

  @override
  Future<Map<String, String>?> buildEnvironment() async {
    if (failSetup) {
      throw StateError('setup-detail');
    }
    return null;
  }

  @override
  Future<File?> resolveCliBinary() async {
    resolveCount += 1;
    return null;
  }

  @override
  Future<Process> startProcess(
    String executable,
    List<String> arguments,
    Map<String, String>? environment,
  ) async {
    startCount += 1;
    throw StateError('unexpected process start');
  }
}

class _LiveProcessContext implements NativeCliProcessContext {
  _LiveProcessContext(this.executable);

  final File executable;
  var startCount = 0;

  @override
  Duration get requestTimeout => const Duration(seconds: 5);

  @override
  Future<Map<String, String>?> buildEnvironment() async => null;

  @override
  Future<File?> resolveCliBinary() async => executable;

  @override
  Future<Process> startProcess(
    String executable,
    List<String> arguments,
    Map<String, String>? environment,
  ) {
    startCount += 1;
    return Process.start(executable, arguments, environment: environment);
  }
}
