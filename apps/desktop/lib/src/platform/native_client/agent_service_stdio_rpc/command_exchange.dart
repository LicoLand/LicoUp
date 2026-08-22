import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc/command_round_trip.dart';
import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc/protocol.dart';
import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc/session_manager.dart';

Future<Map<String, dynamic>> executeStdioRpcCommand({
  required List<String> args,
  required String requestId,
  required String workflowId,
  required StdioRpcSessionManager sessionManager,
}) async {
  final encoded = encodeStdioRpcFrame({
    'protocol': stdioRpcProtocol,
    'id': requestId,
    'workflowId': workflowId,
    'method': 'execute',
    'args': args,
  });
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
  final encoded = encodeStdioRpcFrame({
    'protocol': stdioRpcProtocol,
    'id': requestId,
    'workflowId': workflowId,
    'method': method,
    'params': params,
  });
  return exchangeStdioRpcCommandFrame(
    encoded: encoded,
    requestId: requestId,
    workflowId: workflowId,
    sessionManager: sessionManager,
    recreateIfDeadBeforeWrite: recreateIfDeadBeforeWrite,
  );
}
