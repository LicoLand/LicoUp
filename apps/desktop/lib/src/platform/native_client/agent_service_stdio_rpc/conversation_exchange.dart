import 'package:licoup/src/contracts/generated/client_error.g.dart';
import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc/protocol.dart';
import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc/request_writer.dart';
import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc/response_codec.dart';
import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc/session_manager.dart';
import 'package:licoup/src/platform/native_client/native_cli_ports.dart';

Stream<Map<String, dynamic>> executeStdioRpcConversation({
  required Map<String, dynamic> params,
  required String requestId,
  required String workflowId,
  required StdioRpcSessionManager sessionManager,
}) async* {
  final encoded = encodeStdioRpcFrame({
    'protocol': stdioRpcProtocol,
    'id': requestId,
    'workflowId': workflowId,
    'method': 'agent.conversation.send',
    'params': params,
  });
  final session = await sessionManager.ensureSession();
  late Stream<StdioRpcConversationFrame> frames;
  try {
    frames = session.expectConversationFrames(
      requestId: requestId,
      workflowId: workflowId,
    );
    await writeStdioRpcFrame(session, encoded);
  } on Object {
    session.abandonExpectedFrame(requestId);
    await sessionManager.invalidateAndDiscard();
    throw const LicoClientRpcException('transport_failed');
  }
  var terminalSeen = false;
  try {
    await for (final frame in frames) {
      if (frame is StdioRpcConversationEvent && !terminalSeen) {
        yield frame.event;
        continue;
      }
      if (frame is! StdioRpcConversationTerminal || terminalSeen) {
        throw const LicoClientRpcException('invalid_response');
      }
      terminalSeen = true;
      session.completeExpectedFrames(requestId);
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
  } on Object {
    session.abandonExpectedFrame(requestId);
    await sessionManager.invalidateAndDiscard();
    rethrow;
  }
}
