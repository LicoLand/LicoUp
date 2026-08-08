import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc/command_exchange.dart';
import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc/session_manager.dart';
import 'package:licoup/src/platform/native_client/native_cli_ports.dart';

Future<Map<String, dynamic>> executeStdioRpcInFlightControl({
  required String method,
  required Map<String, dynamic> params,
  required String requestId,
  required String workflowId,
  required Duration timeout,
  required StdioRpcSessionManager sessionManager,
}) {
  return executeStdioRpcStructuredCommand(
    method: method,
    params: params,
    requestId: requestId,
    workflowId: workflowId,
    sessionManager: sessionManager,
  ).timeout(
    timeout,
    onTimeout: () async {
      await sessionManager.invalidateAndDiscard();
      throw const LicoClientRpcException('timeout');
    },
  );
}
