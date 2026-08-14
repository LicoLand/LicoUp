import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc.dart';
import 'package:licoup/src/platform/native_client/native_cli_ports.dart';

void main() {
  test('conversation reconnects by stable handle and ordered cursor', () async {
    if (Platform.isWindows) return;
    final directory = await Directory.systemTemp.createTemp(
      'lico-persistent-runtime-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final executable = File('${directory.path}/licoup');
    final starts = File('${directory.path}/starts');
    await executable.writeAsString(r'''#!/bin/sh
count=0
if [ -f "$LICO_TEST_STARTS" ]; then count=$(cat "$LICO_TEST_STARTS"); fi
count=$((count + 1))
printf '%s' "$count" > "$LICO_TEST_STARTS"
while IFS= read -r line; do
  request_id=$(printf '%s' "$line" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
  workflow_id=$(printf '%s' "$line" | sed -n 's/.*"workflowId":"\([^"]*\)".*/\1/p')
  case "$line" in
    *'"method":"agent.conversation.send"'*)
      printf '{"protocol":"licoup.stdio.v1","id":"%s","workflowId":"%s","kind":"event","sequence":1,"event":{"event":"agent.message.chunk","sessionId":"session-1","turnId":"native-turn-1","turnHandle":"turn-1","conversationId":"conversation-1","cursor":1,"payload":{"ordinal":1}}}\n' "$request_id" "$workflow_id"
      exit 0
      ;;
    *'"method":"agent.conversation.attach"'*'"conversationId":"conversation-1"'*'"afterCursor":1'*)
      printf '{"protocol":"licoup.stdio.v1","id":"%s","workflowId":"%s","kind":"event","sequence":1,"event":{"event":"agent.message.chunk","sessionId":"session-1","turnId":"native-turn-1","turnHandle":"turn-1","conversationId":"conversation-1","cursor":2,"payload":{"ordinal":2}}}\n' "$request_id" "$workflow_id"
      printf '{"protocol":"licoup.stdio.v1","id":"%s","workflowId":"%s","kind":"terminal","sequence":2,"ok":true,"result":{"ok":true,"sessionId":"session-1","turnId":"native-turn-1"}}\n' "$request_id" "$workflow_id"
      exit 0
      ;;
  esac
done
''');
    final chmod = await Process.run('chmod', ['+x', executable.path]);
    expect(chmod.exitCode, 0);
    final context = _ProcessContext(
      executable,
      environment: {'LICO_TEST_STARTS': starts.path},
    );
    final client = NativeStdioRpcClient(processContext: context);
    addTearDown(client.dispose);

    final frames = await client
        .streamConversation(const {'agent': 'synthetic', 'text': 'probe'})
        .toList()
        .timeout(const Duration(seconds: 5));

    expect(
      frames
          .where((frame) => frame['cursor'] is int)
          .map((frame) => frame['cursor']),
      [1, 2],
    );
    expect(frames.last['event'], 'done');
    expect(context.startedArguments, everyElement(['rpc', 'conversation']));
    expect(context.startCount, 2);
  });
}

class _ProcessContext implements NativeCliProcessContext {
  _ProcessContext(this.executable, {this.environment});

  final File executable;
  final Map<String, String>? environment;
  var startCount = 0;
  final startedArguments = <List<String>>[];

  @override
  Duration get requestTimeout => const Duration(seconds: 2);

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
    startedArguments.add(List<String>.from(arguments));
    return Process.start(
      executable,
      arguments,
      environment: environment,
      mode: mode,
    );
  }
}
