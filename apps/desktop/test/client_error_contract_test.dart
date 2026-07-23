import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_client/src/application/features/agents/conversation/conversation_runtime_result_policy.dart';
import 'package:flutter_client/src/application/localization/client_application_strings.dart';
import 'package:flutter_client/src/contracts/generated/client_error.g.dart';
import 'package:flutter_client/src/platform/native_client/agent_service_stdio_rpc/protocol.dart';
import 'package:flutter_client/src/platform/native_client/agent_service_stdio_rpc/response_codec.dart';
import 'package:flutter_test/flutter_test.dart';

const _wireErrors = <Map<String, Object>>[
  {
    'code': 'invalid_request',
    'stage': 'request/validation',
    'component': 'stdio_rpc',
    'retryable': false,
    'recovery': 'correct_request',
    'presentationArgs': <String, String>{'field': 'method'},
  },
  {
    'code': 'agent_runtime_unsupported',
    'stage': 'discovery/adapter',
    'component': 'runtime_adapter',
    'retryable': false,
    'recovery': 'select_supported_adapter',
    'presentationArgs': <String, String>{'agentLabel': 'Fixture Agent'},
  },
  {
    'code': 'native_agent_executable_unavailable',
    'stage': 'process/launch',
    'component': 'runtime_process',
    'retryable': true,
    'recovery': 'install_or_retry_runtime',
    'presentationArgs': <String, String>{'runtimeLabel': 'Fixture Runtime'},
  },
  {
    'code': 'agent_conversation_dispatch_failed',
    'stage': 'conversation/dispatch',
    'component': 'conversation_runtime',
    'retryable': true,
    'recovery': 'preserve_draft_and_retry',
    'presentationArgs': <String, String>{'agentLabel': 'Fixture Agent'},
  },
  {
    'code': 'stream_protocol_failed',
    'stage': 'conversation/stream_receive',
    'component': 'stdio_rpc',
    'retryable': true,
    'recovery': 'preserve_draft_and_retry',
    'presentationArgs': <String, String>{'sequence': '7'},
  },
  {
    'code': 'terminal_result_invalid',
    'stage': 'conversation/terminal_result',
    'component': 'conversation_runtime',
    'retryable': false,
    'recovery': 'review_terminal_result',
    'presentationArgs': <String, String>{'resultKind': 'terminal'},
  },
];

final _wireError = _wireErrors[3];

Uint8List _frame(Map<String, Object?> value) =>
    Uint8List.fromList(utf8.encode(jsonEncode(value)));

void main() {
  test('generated ClientError round trips every bounded field', () {
    final error = ClientError.fromJson(_wireError);

    expect(error.toJson(), _wireError);
    expect(error.presentationArgs, const {'agentLabel': 'Fixture Agent'});
  });

  test('command and terminal decoders preserve every typed error field', () {
    for (var index = 0; index < _wireErrors.length; index += 1) {
      final error = _wireErrors[index];
      final commandRequestId = 'command-$index';
      final terminalRequestId = 'terminal-$index';
      final command = decodeStdioRpcCommandReply(
        _frame({
          'protocol': stdioRpcProtocol,
          'id': commandRequestId,
          'workflowId': 'workflow-1',
          'ok': false,
          'error': error,
        }),
        requestId: commandRequestId,
        workflowId: 'workflow-1',
      );
      final terminal = StdioRpcConversationDecoder(
        requestId: terminalRequestId,
        workflowId: 'workflow-1',
      ).decode(
        _frame({
          'protocol': stdioRpcProtocol,
          'id': terminalRequestId,
          'workflowId': 'workflow-1',
          'kind': 'terminal',
          'sequence': 1,
          'ok': false,
          'error': error,
        }),
      );

      expect(command.error?.toJson(), error, reason: error['stage'] as String);
      expect(terminal, isA<StdioRpcConversationTerminal>());
      expect(
        (terminal as StdioRpcConversationTerminal).error?.toJson(),
        error,
        reason: error['stage'] as String,
      );
    }
  });

  test('a stream event may be followed by a typed terminal error', () {
    final decoder = StdioRpcConversationDecoder(
      requestId: 'stream-request',
      workflowId: 'workflow-1',
    );
    final event = decoder.decode(
      _frame({
          'protocol': stdioRpcProtocol,
          'id': 'stream-request',
        'workflowId': 'workflow-1',
        'kind': 'event',
        'sequence': 1,
        'event': {
          'event': 'dispatch.turn.started',
          'sessionId': 'session-1',
          'turnId': 'turn-1',
        },
      }),
    );
    final terminal = decoder.decode(
      _frame({
          'protocol': stdioRpcProtocol,
          'id': 'stream-request',
        'workflowId': 'workflow-1',
        'kind': 'terminal',
        'sequence': 2,
        'ok': false,
        'error': _wireErrors[4],
      }),
    );

    expect(event, isA<StdioRpcConversationEvent>());
    expect(terminal, isA<StdioRpcConversationTerminal>());
    expect(
      (terminal as StdioRpcConversationTerminal).error?.toJson(),
      _wireErrors[4],
    );
  });

  test('typed recovery preserves the draft and localizes without raw matching', () {
    final error = ClientError.fromJson(_wireError);

    expect(ConversationRuntimeResultPolicy.preserveDraft(error), isTrue);
    expect(
      ClientApplicationStrings.forPreference(
        'en',
      ).conversationClientError(error),
      contains('Fixture Agent'),
    );
    expect(
      ClientApplicationStrings.forPreference(
        'zh',
      ).conversationClientError(error),
      contains('Fixture Agent'),
    );
  });

  test('unknown future values fail safe without exposing their raw values', () {
    final futureStage = ['future', 'private', 'stage'].join('/');
    final error = ClientError.fromJson({
      ..._wireError,
      'code': 'future_private_code',
      'stage': futureStage,
      'recovery': 'future_unsafe_recovery',
      'presentationArgs': const <String, String>{
        'agentLabel': 'Fixture Agent',
        'ignoredFutureArgument': 'must-not-render',
      },
    });
    final policy = ConversationRuntimeResultPolicy.preserveDraft(error);
    final message = ClientApplicationStrings.forPreference(
      'en',
    ).conversationClientError(error);

    expect(policy, isTrue);
    expect(message, isNotEmpty);
    expect(message, isNot(contains('future_private_code')));
    expect(message, isNot(contains(futureStage)));
    expect(message, isNot(contains('future_unsafe_recovery')));
    expect(message, isNot(contains('must-not-render')));
  });
}
