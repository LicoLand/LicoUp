import 'package:licoup/src/contracts/generated/conversation_protocol.g.dart';
import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc/command_round_trip.dart';
import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc/session_manager.dart';
import 'package:licoup/src/platform/native_client/native_cli_ports.dart';

Future<Map<String, dynamic>> executeStdioRpcCommand({
  required List<String> args,
  required String requestId,
  required String workflowId,
  required StdioRpcSessionManager sessionManager,
}) async {
  final encoded = ConversationCommand(
    id: requestId,
    workflowId: workflowId,
    method: ConversationProtocolMethod.execute,
    args: args,
  ).encode();
  return exchangeStdioRpcCommandFrame(
    encoded: encoded,
    requestId: requestId,
    workflowId: workflowId,
    sessionManager: sessionManager,
  );
}

Future<Map<String, dynamic>> executeStdioRpcStructuredCommand({
  required String method,
  required Map<String, dynamic> params,
  required String requestId,
  required String workflowId,
  required StdioRpcSessionManager sessionManager,
  bool recreateIfDeadBeforeWrite = false,
}) async {
  final protocolMethod = ConversationProtocolMethod.fromWire(method);
  if (protocolMethod == null) {
    throw const LicoClientRpcException('invalid_request');
  }
  final encoded = ConversationCommand(
    id: requestId,
    workflowId: workflowId,
    method: protocolMethod,
    params: params,
  ).encode();
  return exchangeStdioRpcCommandFrame(
    encoded: encoded,
    requestId: requestId,
    workflowId: workflowId,
    sessionManager: sessionManager,
    recreateIfDeadBeforeWrite: recreateIfDeadBeforeWrite,
  );
}
