import 'dart:convert';
import 'dart:typed_data';

import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc/protocol.dart';
import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc/response_codec.dart';
import 'package:licoup/src/platform/native_client/native_cli_ports.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('request validation is bounded before serialization', () {
    expect(validStdioRpcArgs(const []), isFalse);
    expect(validStdioRpcArgs(const ['state', 'get']), isTrue);
    expect(
      validStdioRpcArgs(List<String>.filled(stdioRpcMaxArgs + 1, 'x')),
      isFalse,
    );
    expect(
      () => encodeStdioRpcFrame({'unsupported': Object()}),
      throwsA(
        isA<LicoClientRpcException>().having(
          (error) => error.code,
          'code',
          'invalid_request',
        ),
      ),
    );
  });

  test('native error codes allow only bounded lowercase identifiers', () {
    expect(validStdioRpcErrorCode('authorization_required'), isTrue);
    expect(validStdioRpcErrorCode('UPPERCASE'), isFalse);
    expect(validStdioRpcErrorCode('private-detail/value'), isFalse);
    expect(
      validStdioRpcErrorCode(
        List<String>.filled(stdioRpcMaxErrorCodeBytes + 1, 'x').join(),
      ),
      isFalse,
    );
  });

  test(
    'command decoder binds protocol, request, workflow, and result shape',
    () {
      final success = decodeStdioRpcCommandReply(
        _frame({
          'protocol': stdioRpcProtocol,
          'id': 'request-1',
          'workflowId': 'workflow-1',
          'ok': true,
          'result': {'status': 'ok'},
        }),
        requestId: 'request-1',
        workflowId: 'workflow-1',
      );
      expect(success.result, {'status': 'ok'});

      final failure = decodeStdioRpcCommandReply(
        _frame({
          'protocol': stdioRpcProtocol,
          'id': 'request-1',
          'workflowId': 'workflow-1',
          'ok': false,
          'error': {'code': 'authorization_required', 'message': 'private'},
        }),
        requestId: 'request-1',
        workflowId: 'workflow-1',
      );
      expect(failure.error!.code.wireName, 'authorization_required');

      expect(
        () => decodeStdioRpcCommandReply(
          _frame({
            'protocol': stdioRpcProtocol,
            'id': 'different-request',
            'workflowId': 'workflow-1',
            'ok': true,
            'result': <String, dynamic>{},
          }),
          requestId: 'request-1',
          workflowId: 'workflow-1',
        ),
        throwsA(isA<StdioRpcProtocolViolation>()),
      );
    },
  );

  test('conversation decoder accepts one ordered event chain and terminal', () {
    final decoder = StdioRpcConversationDecoder(
      requestId: 'request-1',
      workflowId: 'workflow-1',
    );
    final event = decoder.decode(
      _frame({
        'protocol': stdioRpcProtocol,
        'id': 'request-1',
        'workflowId': 'workflow-1',
        'kind': 'event',
        'sequence': 1,
        'event': {
          'event': 'agent.message.chunk',
          'sessionId': 'session-1',
          'turnId': 'turn-1',
        },
      }),
    );
    expect(event, isA<StdioRpcConversationEvent>());
    final terminal = decoder.decode(
      _frame({
        'protocol': stdioRpcProtocol,
        'id': 'request-1',
        'workflowId': 'workflow-1',
        'kind': 'terminal',
        'sequence': 2,
        'ok': true,
        'result': {'sessionId': 'session-1', 'turnId': 'turn-1'},
      }),
    );
    expect((terminal as StdioRpcConversationTerminal).result, {
      'sessionId': 'session-1',
      'turnId': 'turn-1',
    });
    expect(
      () => decoder.decode(
        _frame({
          'protocol': stdioRpcProtocol,
          'id': 'request-1',
          'workflowId': 'workflow-1',
          'kind': 'terminal',
          'sequence': 3,
          'ok': true,
          'result': <String, dynamic>{},
        }),
      ),
      throwsA(isA<StdioRpcProtocolViolation>()),
    );
  });

  test('conversation decoder rejects gaps and incomplete event identity', () {
    final outOfOrder = StdioRpcConversationDecoder(
      requestId: 'request-1',
      workflowId: 'workflow-1',
    );
    expect(
      () => outOfOrder.decode(
        _frame({
          'protocol': stdioRpcProtocol,
          'id': 'request-1',
          'workflowId': 'workflow-1',
          'kind': 'event',
          'sequence': 2,
          'event': {
            'event': 'agent.message.chunk',
            'sessionId': 'session-1',
            'turnId': 'turn-1',
          },
        }),
      ),
      throwsA(isA<StdioRpcProtocolViolation>()),
    );
    final incomplete = StdioRpcConversationDecoder(
      requestId: 'request-1',
      workflowId: 'workflow-1',
    );
    expect(
      () => incomplete.decode(
        _frame({
          'protocol': stdioRpcProtocol,
          'id': 'request-1',
          'workflowId': 'workflow-1',
          'kind': 'event',
          'sequence': 1,
          'event': {'event': 'agent.message.chunk'},
        }),
      ),
      throwsA(isA<StdioRpcProtocolViolation>()),
    );
  });

  test('conversation decoder accepts persistent events before native ids', () {
    final decoder = StdioRpcConversationDecoder(
      requestId: 'request-1',
      workflowId: 'workflow-1',
    );
    final accepted = decoder.decode(
      _frame({
        'protocol': stdioRpcProtocol,
        'id': 'request-1',
        'workflowId': 'workflow-1',
        'kind': 'event',
        'sequence': 1,
        'event': {
          'event': 'agent.turn.processing',
          'sessionId': '',
          'turnId': '',
          'turnHandle': 'turn-1',
          'conversationId': 'conversation-1',
          'cursor': 1,
        },
      }),
    );
    expect(
      (accepted as StdioRpcConversationEvent).event['turnHandle'],
      'turn-1',
    );
    expect(accepted.event['conversationId'], 'conversation-1');
  });
}

Uint8List _frame(Map<String, dynamic> value) =>
    Uint8List.fromList(utf8.encode(jsonEncode(value)));
