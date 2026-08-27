import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/application/composition/agent_conversation_gateway_adapter.dart';
import 'package:licoup/src/application/features/agents/contracts/agent_conversation_gateway.dart';
import 'package:licoup/src/backend/features/agents/services/agent_conversation_service.dart';
import 'package:licoup/src/contracts/agent_command_runner.dart';
import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc/response_codec.dart';

void main() {
  test('reattached request sequence is independent from turn cursor', () {
    final decoder = StdioRpcConversationDecoder(
      requestId: 'request-attach',
      workflowId: 'workflow-1',
    );
    final event = decoder.decode(
      Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'protocol': 'licoup.stdio.v1',
            'id': 'request-attach',
            'workflowId': 'workflow-1',
            'kind': 'event',
            'sequence': 1,
            'event': {
              'event': 'agent.message.chunk',
              'sessionId': 'session-1',
              'turnId': 'native-turn-1',
              'turnHandle': 'turn-1',
              'conversationId': 'conversation-1',
              'cursor': 42,
              'payload': {'ordinal': 42},
            },
          }),
        ),
      ),
    );

    expect(event, isA<StdioRpcConversationEvent>());
    expect((event as StdioRpcConversationEvent).event['cursor'], 42);
    expect(event.event['turnHandle'], 'turn-1');
  });

  test('replacement gateway discovers and attaches the active turn', () async {
    final runner = _RuntimeRunner();
    final gateway = AgentConversationGatewayAdapter(
      service: const AgentConversationService(),
      runner: runner,
    );
    final persistent = gateway as PersistentAgentConversationGateway;

    final turns = await persistent.activeTurns(
      agentId: 'synthetic',
      sessionId: 'session-1',
      waitForChange: const Duration(milliseconds: 125),
    );
    final events = await persistent
        .attachActiveTurn(
          turnHandle: turns.single['turnHandle'].toString(),
          conversationId: turns.single['conversationId'].toString(),
        )
        .toList();
    final steer = await persistent.steerActiveTurn(
      turnHandle: turns.single['turnHandle'].toString(),
      conversationId: turns.single['conversationId'].toString(),
      text: 'focus',
    );
    final cancel = await persistent.cancelActiveTurn(
      turnHandle: turns.single['turnHandle'].toString(),
      conversationId: turns.single['conversationId'].toString(),
    );

    expect(turns.single['highWater'], 1);
    expect(runner.activeRequest['waitForChangeMs'], 125);
    expect(events.map((event) => event.kind), [
      'agent.message.chunk',
      'dispatch.turn.completed',
    ]);
    expect(events.first.payload['cursor'], 2);
    expect(runner.attachedHandle, 'turn-1');
    expect(runner.attachedConversationId, 'conversation-1');
    expect(steer.ok, isTrue);
    expect(cancel.ok, isTrue);
    expect(runner.controls, [
      'steer:turn-1:conversation-1',
      'cancel:turn-1:conversation-1',
    ]);
  });

  test(
    'failed attach terminal carries a structured failure transition',
    () async {
      final events = await const AgentConversationService()
          .attachActiveTurn(
            runner: _FailedRuntimeRunner(),
            turnHandle: 'turn-1',
            conversationId: 'conversation-1',
          )
          .toList();

      expect(events.single.kind, 'dispatch.turn.failed');
      expect(events.single.payload['terminalTransition'], {
        'kind': 'failed',
        'code': 'cursor_cli_start_failed',
        'stage': 'process/start',
      });
    },
  );
}

class _RuntimeRunner implements AgentCommandRunner {
  String attachedHandle = '';
  String attachedConversationId = '';
  final controls = <String>[];
  Map<String, dynamic> activeRequest = const {};

  @override
  Future<Map<String, dynamic>> runCli(List<String> args) async => const {};

  @override
  Future<Map<String, dynamic>> runCliWithStdin(
    List<String> args,
    String stdinText,
  ) async {
    final operation = args[2];
    if (operation == 'steer' || operation == 'cancel') {
      final request = jsonDecode(stdinText) as Map<String, dynamic>;
      controls.add(
        '$operation:${request['turnHandle']}:${request['conversationId']}',
      );
      return {
        'ok': true,
        'status': operation == 'steer' ? 'steered' : 'cancelled',
      };
    }
    expect(operation, 'active');
    activeRequest = Map<String, dynamic>.from(jsonDecode(stdinText) as Map);
    return {
      'turns': [
        {
          'turnHandle': 'turn-1',
          'conversationId': 'conversation-1',
          'agent': 'synthetic',
          'sessionId': 'session-1',
          'turnId': 'native-turn-1',
          'highWater': 1,
        },
      ],
    };
  }

  @override
  Stream<Map<String, dynamic>> streamCliJsonLines(List<String> args) =>
      const Stream.empty();

  @override
  Stream<Map<String, dynamic>> streamCliJsonLinesWithStdin(
    List<String> args,
    String stdinText,
  ) async* {
    expect(args[2], 'attach');
    final request = jsonDecode(stdinText) as Map<String, dynamic>;
    attachedHandle = request['turnHandle'].toString();
    attachedConversationId = request['conversationId'].toString();
    yield {
      'event': 'agent.message.chunk',
      'sessionId': 'session-1',
      'turnId': 'native-turn-1',
      'turnHandle': 'turn-1',
      'conversationId': 'conversation-1',
      'cursor': 2,
      'payload': {'text': 'continued'},
    };
    yield {
      'event': 'done',
      'ok': true,
      'sessionId': 'session-1',
      'turnId': 'native-turn-1',
    };
  }
}

final class _FailedRuntimeRunner extends _RuntimeRunner {
  @override
  Stream<Map<String, dynamic>> streamCliJsonLinesWithStdin(
    List<String> args,
    String stdinText,
  ) async* {
    yield {
      'event': 'done',
      'ok': false,
      'error': {'code': 'cursor_cli_start_failed', 'stage': 'process/start'},
    };
  }
}
