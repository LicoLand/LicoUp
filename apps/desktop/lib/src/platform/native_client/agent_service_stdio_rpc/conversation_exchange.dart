import 'dart:async';

import 'package:licoup/src/contracts/generated/client_error.g.dart';
import 'package:licoup/src/contracts/generated/conversation_protocol.g.dart';
import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc/request_writer.dart';
import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc/response_codec.dart';
import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc/session.dart';
import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc/session_manager.dart';
import 'package:licoup/src/platform/native_client/native_cli_ports.dart';

Stream<Map<String, dynamic>> executeStdioRpcConversation({
  required Map<String, dynamic> params,
  required String requestId,
  required String workflowId,
  required StdioRpcSessionManager sessionManager,
}) async* {
  const maxReconnects = 1;
  final wireParams = Map<String, dynamic>.from(params);
  final initialOperation = (wireParams.remove('_rpcOperation') ?? 'send')
      .toString();
  var turnHandle = (wireParams['turnHandle'] ?? '').toString();
  var conversationId = (wireParams['conversationId'] ?? '').toString();
  var cursor = wireParams['afterCursor'] is int
      ? wireParams['afterCursor'] as int
      : 0;
  var reconnects = 0;
  while (true) {
    final activeRequestId = reconnects == 0
        ? requestId
        : '$requestId-attach-$reconnects';
    final operationMethod = ConversationProtocolMethod.fromWire(
      'agent.conversation.$initialOperation',
    );
    final attachMethod = ConversationProtocolMethod.fromWire(
      'agent.conversation.attach',
    );
    if (operationMethod == null || attachMethod == null) {
      throw const LicoClientRpcException('invalid_request');
    }
    final encoded = ConversationCommand(
      id: activeRequestId,
      workflowId: workflowId,
      method: reconnects == 0 ? operationMethod : attachMethod,
      params: reconnects == 0
          ? wireParams
          : <String, dynamic>{
              'turnHandle': turnHandle,
              'conversationId': conversationId,
              'afterCursor': cursor,
            },
    ).encode();
    StdioRpcSession? session;
    try {
      session = await sessionManager.ensureSession();
      final frames = session.expectConversationFrames(
        requestId: activeRequestId,
        workflowId: workflowId,
      );
      await writeStdioRpcFrame(session, encoded);
      var terminalSeen = false;
      await for (final frame in frames) {
        if (frame is StdioRpcConversationEvent && !terminalSeen) {
          final eventHandle = (frame.event['turnHandle'] ?? '').toString();
          final eventConversationId = (frame.event['conversationId'] ?? '')
              .toString();
          final eventCursor = frame.event['cursor'];
          if (eventHandle.isNotEmpty) {
            if (turnHandle.isNotEmpty && turnHandle != eventHandle) {
              throw const LicoClientRpcException('invalid_response');
            }
            turnHandle = eventHandle;
          }
          if (eventConversationId.isNotEmpty) {
            if (conversationId.isNotEmpty &&
                conversationId != eventConversationId) {
              throw const LicoClientRpcException('invalid_response');
            }
            conversationId = eventConversationId;
          }
          if (eventCursor is int) {
            if (eventCursor <= cursor) {
              continue;
            }
            if (eventCursor != cursor + 1) {
              throw const LicoClientRpcException('invalid_response');
            }
            cursor = eventCursor;
          }
          yield frame.event;
          continue;
        }
        if (frame is! StdioRpcConversationTerminal || terminalSeen) {
          throw const LicoClientRpcException('invalid_response');
        }
        terminalSeen = true;
        session.completeExpectedFrames(activeRequestId);
        final result = frame.result;
        if (result != null) {
          yield <String, dynamic>{...result, 'event': 'done'};
          return;
        }
        final ClientError error =
            frame.error ??
            ClientError.fromJson(const <String, Object?>{
              'code': 'terminal_result_invalid',
              'stage': 'conversation/terminal_result',
              'component': 'conversation_runtime',
              'retryable': false,
              'recovery': 'review_terminal_result',
            });
        yield <String, dynamic>{
          'ok': false,
          'error': error.toJson(),
          'event': 'done',
        };
        return;
      }
      if (!terminalSeen) {
        throw const LicoClientRpcException('transport_failed');
      }
    } on Object catch (error) {
      session?.abandonExpectedFrame(activeRequestId);
      await sessionManager.invalidateAndDiscard();
      if (turnHandle.isEmpty ||
          conversationId.isEmpty ||
          reconnects >= maxReconnects) {
        if (error is LicoClientRpcException) rethrow;
        throw const LicoClientRpcException('transport_failed');
      }
      reconnects += 1;
    }
  }
}
