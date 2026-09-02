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
      final releaseFile = File('${directory.path}/release-command');
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
      while [ ! -f "$LICO_TEST_RELEASE_FILE" ]; do sleep 0.01; done
      printf '{"protocol":"licoup.stdio.v1","id":"%s","workflowId":"%s","ok":true,"result":{}}\n' "$request_id" "$workflow_id"
      ;;
  esac
done
''');
      final chmod = await Process.run('chmod', ['+x', executable.path]);
      expect(chmod.exitCode, 0);
      final context = _LiveProcessContext(
        executable,
        requestTimeout: const Duration(seconds: 15),
        environment: {'LICO_TEST_RELEASE_FILE': releaseFile.path},
      );
      final client = NativeStdioRpcClient(processContext: context);
      addTearDown(client.dispose);

      final pendingCommand = client.execute(const ['slow-command']);
      try {
        await _waitUntil(() => context.startCount == 1);
        final conversation = await client
            .streamConversation(const {'agent': 'claude-code', 'text': 'probe'})
            .toList()
            .timeout(const Duration(seconds: 10));

        expect(context.startCount, 2);
        expect(conversation.last['event'], 'done');
      } finally {
        await releaseFile.writeAsString('release');
      }
      await pendingCommand.timeout(const Duration(seconds: 5));
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

  test(
    'structured mentioned group turn RPC is not limited by ordinary timeout',
    () async {
      if (Platform.isWindows) return;
      final directory = await Directory.systemTemp.createTemp(
        'lico-stdio-direct-turn-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final executable = File('${directory.path}/licoup');
      await executable.writeAsString(r'''#!/bin/sh
while IFS= read -r line; do
  request_id=$(printf '%s' "$line" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
  workflow_id=$(printf '%s' "$line" | sed -n 's/.*"workflowId":"\([^"]*\)".*/\1/p')
  case "$line" in
    *'"method":"client.conversation.execute"'*'"action":"conversation.dispatch.after-post"'*)
      sleep 1
      printf '{"protocol":"licoup.stdio.v1","id":"%s","workflowId":"%s","ok":true,"result":{"ok":true,"directTurns":[{"state":"succeeded"}]}}\n' "$request_id" "$workflow_id"
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
      final context = _LiveProcessContext(
        executable,
        requestTimeout: const Duration(milliseconds: 100),
      );
      final client = NativeStdioRpcClient(processContext: context);
      addTearDown(client.dispose);

      final result = await client
          .executeStructured('client.conversation.execute', const {
            'action': 'conversation.dispatch.after-post',
            'conversationId': 'conversation:group',
            'eventId': 'event:posted',
          })
          .timeout(const Duration(seconds: 3));

      expect(result['ok'], isTrue);
      expect(result['directTurns'], isNotEmpty);
      expect(context.startCount, 1);
    },
  );

  test(
    'client state migration admission may outwait the ordinary RPC timeout',
    () async {
      if (Platform.isWindows) return;
      final directory = await Directory.systemTemp.createTemp(
        'lico-stdio-migration-admit-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final executable = File('${directory.path}/licoup');
      await executable.writeAsString(r'''#!/bin/sh
while IFS= read -r line; do
  request_id=$(printf '%s' "$line" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
  workflow_id=$(printf '%s' "$line" | sed -n 's/.*"workflowId":"\([^"]*\)".*/\1/p')
  case "$line" in
    *'"method":"execute"'*'"state","admit"'*)
      sleep 1
      printf '{"protocol":"licoup.stdio.v1","id":"%s","workflowId":"%s","ok":true,"result":{"ok":true,"phase":"admitted"}}\n' "$request_id" "$workflow_id"
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
      final context = _LiveProcessContext(
        executable,
        requestTimeout: const Duration(milliseconds: 100),
      );
      final client = NativeStdioRpcClient(processContext: context);
      addTearDown(client.dispose);

      final result = await client
          .execute(const ['state', 'admit', '/fixture/data'])
          .timeout(const Duration(seconds: 3));

      expect(result['ok'], isTrue);
      expect(result['phase'], 'admitted');
      expect(context.startCount, 1);
    },
  );

  test(
    'conversation command EOF reconnects once without replaying the command',
    () async {
      if (Platform.isWindows) return;
      final directory = await Directory.systemTemp.createTemp(
        'lico-stdio-eof-reconnect-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final executable = File('${directory.path}/licoup');
      final firstStarted = File('${directory.path}/first-started');
      final commands = File('${directory.path}/commands');
      await executable.writeAsString(r'''#!/bin/sh
if [ ! -f "$LICO_TEST_FIRST_STARTED" ]; then
  : > "$LICO_TEST_FIRST_STARTED"
  first=1
else
  first=0
fi
while IFS= read -r line; do
  case "$line" in
    *'"method":"agent.conversation.active"'*)
      printf '%s\n' "$line" >> "$LICO_TEST_COMMAND_FILE"
      if [ "$first" -eq 1 ]; then
        exit 0
      fi
      ;;
  esac
done
''');
      final chmod = await Process.run('chmod', ['+x', executable.path]);
      expect(chmod.exitCode, 0);
      final context = _LiveProcessContext(
        executable,
        environment: {
          'LICO_TEST_FIRST_STARTED': firstStarted.path,
          'LICO_TEST_COMMAND_FILE': commands.path,
        },
      );
      final client = NativeStdioRpcClient(processContext: context);
      addTearDown(client.dispose);

      await expectLater(
        client.executeStructured('agent.conversation.active', const {
          'conversationId': 'conversation:group',
        }),
        throwsA(
          isA<LicoClientRpcException>().having(
            (error) => error.code,
            'code',
            'transport_failed',
          ),
        ),
      );
      await _waitUntil(() => context.startCount == 2);

      expect(await commands.readAsLines(), hasLength(1));
      expect(context.startCount, 2);
    },
  );

  test('conversation observer reconnects once from the last cursor', () async {
    if (Platform.isWindows) return;
    final directory = await Directory.systemTemp.createTemp(
      'lico-stdio-observer-reconnect-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final executable = File('${directory.path}/licoup');
    final firstStarted = File('${directory.path}/first-started');
    final attachRequest = File('${directory.path}/attach-request');
    await executable.writeAsString(r'''#!/bin/sh
if [ ! -f "$LICO_TEST_FIRST_STARTED" ]; then
  : > "$LICO_TEST_FIRST_STARTED"
  first=1
else
  first=0
fi
while IFS= read -r line; do
  request_id=$(printf '%s' "$line" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
  workflow_id=$(printf '%s' "$line" | sed -n 's/.*"workflowId":"\([^"]*\)".*/\1/p')
  if [ "$first" -eq 1 ]; then
    printf '{"protocol":"licoup.stdio.v1","id":"%s","workflowId":"%s","kind":"event","sequence":1,"event":{"event":"agent.message.chunk","turnHandle":"dispatch:live","conversationId":"conversation:group","cursor":1,"payload":{"text":"first"}}}\n' "$request_id" "$workflow_id"
    exit 0
  fi
  printf '%s\n' "$line" > "$LICO_TEST_ATTACH_REQUEST"
  printf '{"protocol":"licoup.stdio.v1","id":"%s","workflowId":"%s","kind":"event","sequence":1,"event":{"event":"agent.message.chunk","turnHandle":"dispatch:live","conversationId":"conversation:group","cursor":2,"payload":{"text":"second"}}}\n' "$request_id" "$workflow_id"
  printf '{"protocol":"licoup.stdio.v1","id":"%s","workflowId":"%s","kind":"terminal","sequence":2,"ok":true,"result":{"ok":true}}\n' "$request_id" "$workflow_id"
done
''');
    final chmod = await Process.run('chmod', ['+x', executable.path]);
    expect(chmod.exitCode, 0);
    final context = _LiveProcessContext(
      executable,
      environment: {
        'LICO_TEST_FIRST_STARTED': firstStarted.path,
        'LICO_TEST_ATTACH_REQUEST': attachRequest.path,
      },
    );
    final client = NativeStdioRpcClient(processContext: context);
    addTearDown(client.dispose);

    final events = await client
        .streamConversation(const {
          'agent': 'synthetic',
          'text': 'synthetic prompt',
          'conversationId': 'conversation:group',
        })
        .toList()
        .timeout(const Duration(seconds: 5));

    expect(events.map((event) => event['cursor']).whereType<int>(), [1, 2]);
    expect(events.last['event'], 'done');
    expect(context.startCount, 2);
    final attach = await attachRequest.readAsString();
    expect(attach, contains('"method":"agent.conversation.attach"'));
    expect(attach, contains('"afterCursor":1'));
  });

  test(
    'cancelling an observer releases the conversation lane before turn completion',
    () async {
      if (Platform.isWindows) return;
      final directory = await Directory.systemTemp.createTemp(
        'lico-stdio-observer-detach-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final executable = File('${directory.path}/licoup');
      final release = File('${directory.path}/release');
      final completed = File('${directory.path}/completed');
      await executable.writeAsString(r'''#!/bin/sh
while IFS= read -r line; do
  request_id=$(printf '%s' "$line" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
  workflow_id=$(printf '%s' "$line" | sed -n 's/.*"workflowId":"\([^"]*\)".*/\1/p')
  case "$line" in
    *'"method":"agent.conversation.send"'*)
      printf '{"protocol":"licoup.stdio.v1","id":"%s","workflowId":"%s","kind":"event","sequence":1,"event":{"event":"agent.message.chunk","turnHandle":"dispatch:live","conversationId":"conversation:group","cursor":1,"payload":{"text":"working"}}}\n' "$request_id" "$workflow_id"
      (
        while [ ! -f "$LICO_TEST_RELEASE_FILE" ]; do sleep 0.01; done
        printf '{"protocol":"licoup.stdio.v1","id":"%s","workflowId":"%s","kind":"terminal","sequence":2,"ok":true,"result":{"ok":true}}\n' "$request_id" "$workflow_id"
        : > "$LICO_TEST_COMPLETED_FILE"
      ) &
      ;;
    *'"method":"agent.conversation.active"'*)
      printf '{"protocol":"licoup.stdio.v1","id":"%s","workflowId":"%s","ok":true,"result":{"turns":[]}}\n' "$request_id" "$workflow_id"
      ;;
  esac
done
''');
      final chmod = await Process.run('chmod', ['+x', executable.path]);
      expect(chmod.exitCode, 0);
      final context = _LiveProcessContext(
        executable,
        environment: {
          'LICO_TEST_RELEASE_FILE': release.path,
          'LICO_TEST_COMPLETED_FILE': completed.path,
        },
      );
      final client = NativeStdioRpcClient(processContext: context);
      addTearDown(client.dispose);
      final events = <Map<String, dynamic>>[];
      final subscription = client
          .streamConversation(const {
            'agent': 'synthetic',
            'text': 'synthetic prompt',
            'conversationId': 'conversation:group',
          })
          .listen(events.add);

      await _waitUntil(() => events.isNotEmpty);
      final detached = subscription.cancel();
      final active = await client
          .executeStructured('agent.conversation.active', const {
            'conversationId': 'conversation:group',
          })
          .timeout(const Duration(seconds: 1));

      expect(active['turns'], isEmpty);
      expect(context.startCount, 1);
      expect(completed.existsSync(), isFalse);
      await release.writeAsString('release');
      await _waitUntil(completed.existsSync);
      await detached.timeout(const Duration(seconds: 1));
    },
  );

  test(
    'disposing the client detaches without terminating active conversation work',
    () async {
      if (Platform.isWindows) return;
      final directory = await Directory.systemTemp.createTemp(
        'lico-stdio-detach-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final executable = File('${directory.path}/licoup');
      final started = File('${directory.path}/started');
      final release = File('${directory.path}/release');
      final completed = File('${directory.path}/completed');
      await executable.writeAsString(r'''#!/bin/sh
while IFS= read -r line; do
  request_id=$(printf '%s' "$line" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
  workflow_id=$(printf '%s' "$line" | sed -n 's/.*"workflowId":"\([^"]*\)".*/\1/p')
  case "$line" in
    *'"method":"agent.conversation.send"'*)
      : > "$LICO_TEST_STARTED_FILE"
      (
        while [ ! -f "$LICO_TEST_RELEASE_FILE" ]; do sleep 0.01; done
        : > "$LICO_TEST_COMPLETED_FILE"
      ) &
      worker=$!
      wait "$worker"
      printf '{"protocol":"licoup.stdio.v1","id":"%s","workflowId":"%s","kind":"terminal","sequence":1,"ok":true,"result":{"sessionId":"session-1","turnId":"turn-1"}}\n' "$request_id" "$workflow_id" || true
      ;;
  esac
done
''');
      final chmod = await Process.run('chmod', ['+x', executable.path]);
      expect(chmod.exitCode, 0);
      final context = _LiveProcessContext(
        executable,
        environment: {
          'LICO_TEST_STARTED_FILE': started.path,
          'LICO_TEST_RELEASE_FILE': release.path,
          'LICO_TEST_COMPLETED_FILE': completed.path,
        },
      );
      final client = NativeStdioRpcClient(processContext: context);
      final streamDone = Completer<void>();
      client
          .streamConversation(const {
            'agent': 'codex',
            'text': 'synthetic work',
          })
          .listen(
            (_) {},
            onError: (Object _, StackTrace _) {},
            onDone: streamDone.complete,
          );

      await _waitUntil(
        started.existsSync,
        timeout: const Duration(seconds: 10),
      );
      expect(context.startModes, [ProcessStartMode.normal]);
      await client.dispose().timeout(const Duration(milliseconds: 500));
      await streamDone.future.timeout(const Duration(milliseconds: 500));
      expect(completed.existsSync(), isFalse);

      await release.writeAsString('release');
      await _waitUntil(
        completed.existsSync,
        timeout: const Duration(seconds: 10),
      );
      expect(context.startCount, 1);
    },
  );
}

Future<void> _waitUntil(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
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
    Map<String, String>? environment, {
    ProcessStartMode mode = ProcessStartMode.normal,
  }) async {
    startCount += 1;
    throw StateError('unexpected process start');
  }
}

class _LiveProcessContext implements NativeCliProcessContext {
  _LiveProcessContext(
    this.executable, {
    this.requestTimeout = const Duration(seconds: 5),
    this.environment,
  });

  final File executable;
  final Map<String, String>? environment;
  @override
  final Duration requestTimeout;
  var startCount = 0;
  final startModes = <ProcessStartMode>[];

  @override
  Future<Map<String, String>?> buildEnvironment() async => environment;

  @override
  Future<File?> resolveCliBinary() async => executable;

  @override
  Future<Process> startProcess(
    String executable,
    List<String> arguments,
    Map<String, String>? environment, {
    ProcessStartMode mode = ProcessStartMode.normal,
  }) {
    startCount += 1;
    startModes.add(mode);
    return Process.start(
      executable,
      arguments,
      environment: environment,
      mode: mode,
    );
  }
}
