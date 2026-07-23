import 'package:flutter_client/src/platform/native_client/agent_service_stdio_rpc/protocol.dart';
import 'package:flutter_client/src/platform/native_client/agent_service_stdio_rpc/request_writer.dart';
import 'package:flutter_client/src/platform/native_client/agent_service_stdio_rpc/response_codec.dart';
import 'package:flutter_client/src/platform/native_client/agent_service_stdio_rpc/session.dart';
import 'package:flutter_client/src/platform/native_client/agent_service_stdio_rpc/session_manager.dart';

Future<void> shutdownStdioRpcManager({
  required StdioRpcSessionManager manager,
  required String requestId,
  required String workflowId,
}) async {
  final session = manager.takeForShutdown();
  if (session == null) return;
  await shutdownStdioRpcSession(
    session: session,
    requestId: requestId,
    workflowId: workflowId,
  );
}

Future<void> shutdownStdioRpcSession({
  required StdioRpcSession session,
  required String requestId,
  required String workflowId,
}) async {
  final frame = encodeStdioRpcFrame({
    'protocol': stdioRpcProtocol,
    'id': requestId,
    'workflowId': workflowId,
    'method': 'shutdown',
  });
  var acknowledged = false;
  try {
    final responseFuture = session.expectFrame();
    await writeStdioRpcFrame(session, frame);
    final responseFrame = await responseFuture.timeout(stdioRpcShutdownTimeout);
    final response = responseFrame.bytes;
    acknowledged =
        response != null &&
        isStdioRpcShutdownAcknowledged(
          response,
          requestId: requestId,
          workflowId: workflowId,
        );
  } on Object {
    session.abandonExpectedFrame();
  }
  await session.close(kill: !acknowledged);
}
