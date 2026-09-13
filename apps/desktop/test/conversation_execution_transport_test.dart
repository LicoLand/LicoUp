import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc.dart';
import 'package:licoup/src/platform/native_client/native_cli_ports.dart';

void main() {
  test(
    'execution transport preserves opaque cursor gaps and all same-cursor fragments',
    () async {
      if (Platform.isWindows) return;
      final directory = await Directory.systemTemp.createTemp(
        'lico-execution-transport-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final executable = File('${directory.path}/fixture');
      await executable.writeAsString(r'''#!/bin/sh
while IFS= read -r line; do
  request_id=$(printf '%s' "$line" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
  workflow_id=$(printf '%s' "$line" | sed -n 's/.*"workflowId":"\([^"]*\)".*/\1/p')
  case "$line" in
    *'"method":"agent.conversation.execution"'*)
      printf '{"protocol":"licoup.stdio.v1","id":"%s","workflowId":"%s","kind":"event","sequence":1,"event":{"event":"agent.execution.record","turnHandle":"dispatch-fixture","conversationId":"conversation-fixture","membershipId":"membership-fixture","cursor":7,"partIndex":0,"partCount":2,"record":{"id":"record-7","cursor":7,"rawText":"first"}}}\n' "$request_id" "$workflow_id"
      printf '{"protocol":"licoup.stdio.v1","id":"%s","workflowId":"%s","kind":"event","sequence":2,"event":{"event":"agent.execution.record","turnHandle":"dispatch-fixture","conversationId":"conversation-fixture","membershipId":"membership-fixture","cursor":7,"partIndex":1,"partCount":2,"record":{"id":"record-7","cursor":7,"rawText":"second"}}}\n' "$request_id" "$workflow_id"
      printf '{"protocol":"licoup.stdio.v1","id":"%s","workflowId":"%s","kind":"event","sequence":3,"event":{"event":"agent.execution.ready","turnHandle":"dispatch-fixture","conversationId":"conversation-fixture","membershipId":"membership-fixture","cursor":7,"status":"completed","observationAvailable":false,"terminalPayloadAvailable":true}}\n' "$request_id" "$workflow_id"
      printf '{"protocol":"licoup.stdio.v1","id":"%s","workflowId":"%s","kind":"terminal","sequence":4,"ok":true,"result":{"turnHandle":"dispatch-fixture","conversationId":"conversation-fixture","membershipId":"membership-fixture","cursor":7,"status":"completed","observationAvailable":false,"terminalPayloadAvailable":true}}\n' "$request_id" "$workflow_id"
      ;;
    *'"method":"shutdown"'*)
      printf '{"protocol":"licoup.stdio.v1","id":"%s","workflowId":"%s","ok":true,"result":{}}\n' "$request_id" "$workflow_id"
      exit 0
      ;;
  esac
done
''');
      expect((await Process.run('chmod', ['+x', executable.path])).exitCode, 0);
      final client = NativeStdioRpcClient(processContext: _Context(executable));
      addTearDown(client.dispose);
      final events = await client.streamConversation(const {
        '_rpcOperation': 'execution',
        'turnHandle': 'dispatch-fixture',
        'conversationId': 'conversation-fixture',
        'membershipId': 'membership-fixture',
        'afterCursor': 1,
      }).toList();
      expect(events, hasLength(4));
      expect(events.take(2).map((event) => event['partIndex']), [0, 1]);
      expect(events[2]['event'], 'agent.execution.ready');
      expect(events.last['event'], 'done');
    },
  );

  test(
    'execution observer EOF never changes the request to public attach',
    () async {
      if (Platform.isWindows) return;
      final directory = await Directory.systemTemp.createTemp(
        'lico-execution-eof-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final executable = File('${directory.path}/fixture');
      await executable.writeAsString('#!/bin/sh\nIFS= read -r line\nexit 0\n');
      expect((await Process.run('chmod', ['+x', executable.path])).exitCode, 0);
      final context = _Context(executable);
      final client = NativeStdioRpcClient(processContext: context);
      addTearDown(client.dispose);
      await expectLater(
        client.streamConversation(const {
          '_rpcOperation': 'execution',
          'turnHandle': 'dispatch-fixture',
          'conversationId': 'conversation-fixture',
          'membershipId': 'membership-fixture',
        }).toList(),
        throwsA(isA<LicoClientRpcException>()),
      );
      expect(context.starts, 1);
    },
  );

  test(
    'closing and reopening execution observations releases slots and leaves another live stream intact',
    () async {
      if (Platform.isWindows) return;
      final directory = await Directory.systemTemp.createTemp(
        'lico-execution-detach-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final executable = File('${directory.path}/fixture');
      await executable.writeAsString(r'''#!/bin/sh
live_id=
live_workflow=
live_sequence=0
while IFS= read -r line; do
  request_id=$(printf '%s' "$line" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
  workflow_id=$(printf '%s' "$line" | sed -n 's/.*"workflowId":"\([^"]*\)".*/\1/p')
  case "$line" in
    *'"method":"agent.conversation.send"'*)
      live_id=$request_id
      live_workflow=$workflow_id
      live_sequence=1
      printf '{"protocol":"licoup.stdio.v1","id":"%s","workflowId":"%s","kind":"event","sequence":1,"event":{"event":"agent.message.chunk","turnHandle":"other-dispatch","conversationId":"other-conversation","cursor":1,"payload":{"text":"still running"}}}\n' "$live_id" "$live_workflow"
      ;;
    *'"method":"agent.conversation.execution"'*)
      observed_id=$request_id
      observed_workflow=$workflow_id
      printf '{"protocol":"licoup.stdio.v1","id":"%s","workflowId":"%s","kind":"event","sequence":1,"event":{"event":"agent.execution.ready","turnHandle":"dispatch-fixture","conversationId":"conversation-fixture","membershipId":"membership-fixture","cursor":0,"status":"running","observationAvailable":true,"terminalPayloadAvailable":false}}\n' "$observed_id" "$observed_workflow"
      ;;
    *'"method":"agent.conversation.execution.detach"'*)
      printf '{"protocol":"licoup.stdio.v1","id":"%s","workflowId":"%s","kind":"event","sequence":2,"event":{"event":"agent.execution.record","turnHandle":"dispatch-fixture","conversationId":"conversation-fixture","membershipId":"membership-fixture","cursor":3,"partIndex":0,"partCount":1,"record":{"id":"late-fixture","cursor":3,"rawText":"late frame"}}}\n' "$observed_id" "$observed_workflow"
      printf '{"protocol":"licoup.stdio.v1","id":"%s","workflowId":"%s","kind":"terminal","sequence":3,"ok":true,"result":{"turnHandle":"dispatch-fixture","conversationId":"conversation-fixture","membershipId":"membership-fixture","cursor":3,"status":"running","observationAvailable":false,"terminalPayloadAvailable":false,"detached":true}}\n' "$observed_id" "$observed_workflow"
      printf '{"protocol":"licoup.stdio.v1","id":"%s","workflowId":"%s","ok":true,"result":{"detached":true}}\n' "$request_id" "$workflow_id"
      live_sequence=$((live_sequence + 1))
      printf '{"protocol":"licoup.stdio.v1","id":"%s","workflowId":"%s","kind":"event","sequence":%s,"event":{"event":"agent.message.chunk","turnHandle":"other-dispatch","conversationId":"other-conversation","cursor":%s,"payload":{"text":"still running"}}}\n' "$live_id" "$live_workflow" "$live_sequence" "$live_sequence"
      ;;
    *'"method":"agent.conversation.steer"'*)
      printf '{"protocol":"licoup.stdio.v1","id":"%s","workflowId":"%s","ok":true,"result":{"ok":true}}\n' "$request_id" "$workflow_id"
      live_sequence=$((live_sequence + 1))
      printf '{"protocol":"licoup.stdio.v1","id":"%s","workflowId":"%s","kind":"terminal","sequence":%s,"ok":true,"result":{"ok":true}}\n' "$live_id" "$live_workflow" "$live_sequence"
      ;;
    *'"method":"shutdown"'*)
      printf '{"protocol":"licoup.stdio.v1","id":"%s","workflowId":"%s","ok":true,"result":{}}\n' "$request_id" "$workflow_id"
      exit 0
      ;;
  esac
done
''');
      expect((await Process.run('chmod', ['+x', executable.path])).exitCode, 0);
      final context = _Context(executable);
      final client = NativeStdioRpcClient(processContext: context);
      addTearDown(client.dispose);
      final liveEvents = <Map<String, dynamic>>[];
      final liveErrors = <Object>[];
      final started = Completer<void>();
      final live = client
          .streamConversation(const {
            'agent': 'synthetic',
            'text': 'synthetic request',
          })
          .listen((event) {
            liveEvents.add(event);
            if (!started.isCompleted) started.complete();
          }, onError: liveErrors.add);
      await started.future;
      for (var index = 0; index < 70; index++) {
        final ready = Completer<void>();
        final observation = client
            .streamConversation(const {
              '_rpcOperation': 'execution',
              'turnHandle': 'dispatch-fixture',
              'conversationId': 'conversation-fixture',
              'membershipId': 'membership-fixture',
            })
            .listen((event) {
              if (!ready.isCompleted) ready.complete();
            }, onError: (Object error) => ready.completeError(error));
        await ready.future;
        await observation.cancel();
      }
      await Future<void>.delayed(Duration.zero);
      expect(context.starts, 1);
      expect(liveErrors, isEmpty);
      expect(liveEvents.length, greaterThanOrEqualTo(70));
      await client.executeStructured('agent.conversation.steer', const {
        'agent': 'synthetic',
        'text': 'finish fixture',
      });
      await live.cancel();
    },
  );
}

final class _Context implements NativeCliProcessContext {
  _Context(this.executable);
  final File executable;
  var starts = 0;
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
    Map<String, String>? environment, {
    ProcessStartMode mode = ProcessStartMode.normal,
  }) {
    starts++;
    return Process.start(
      executable,
      arguments,
      environment: environment,
      mode: mode,
    );
  }
}
