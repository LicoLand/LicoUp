import 'package:flutter_client/src/platform/native_client/agent_service_stdio_rpc/command_exchange.dart';
import 'package:flutter_client/src/platform/native_client/agent_service_stdio_rpc/conversation_exchange.dart';
import 'package:flutter_client/src/platform/native_client/agent_service_stdio_rpc/operation_queue.dart';
import 'package:flutter_client/src/platform/native_client/agent_service_stdio_rpc/protocol.dart';
import 'package:flutter_client/src/platform/native_client/agent_service_stdio_rpc/session_manager.dart';
import 'package:flutter_client/src/platform/native_client/agent_service_stdio_rpc/shutdown.dart';
import 'package:flutter_client/src/platform/native_client/native_cli_ports.dart';

class NativeStdioRpcClient implements NativeStdioRpcTransport {
  NativeStdioRpcClient({required NativeCliProcessContext processContext})
    : _processContext = processContext,
      _sessionManager = StdioRpcSessionManager(processContext: processContext);

  final NativeCliProcessContext _processContext;
  final StdioRpcSessionManager _sessionManager;
  final StdioRpcOperationQueue _operations = StdioRpcOperationQueue();
  late final String _workflowId = newStdioRpcWorkflowId();
  var _requestSequence = 0;

  @override
  Future<Map<String, dynamic>> execute(List<String> args) {
    if (_operations.closing) {
      return Future<Map<String, dynamic>>.error(
        const LicoClientRpcException('service_disposed'),
      );
    }
    if (_processContext.requestTimeout <= Duration.zero) {
      return Future<Map<String, dynamic>>.error(
        const LicoClientRpcException('invalid_timeout'),
      );
    }
    if (!validStdioRpcArgs(args)) {
      return Future<Map<String, dynamic>>.error(
        const LicoClientRpcException('invalid_request'),
      );
    }
    final requestArgs = List<String>.unmodifiable(args);
    return _operations.serialize(
      () =>
          executeStdioRpcCommand(
            args: requestArgs,
            requestId: _nextRequestId(),
            workflowId: _workflowId,
            sessionManager: _sessionManager,
          ).timeout(
            _processContext.requestTimeout,
            onTimeout: () async {
              await _sessionManager.invalidateAndDiscard();
              throw const LicoClientRpcException('timeout');
            },
          ),
    );
  }

  @override
  Future<Map<String, dynamic>> executeStructured(
    String method,
    Map<String, dynamic> params,
  ) {
    if (_operations.closing || !method.startsWith('catalog.')) {
      return Future<Map<String, dynamic>>.error(
        const LicoClientRpcException('invalid_request'),
      );
    }
    if (_processContext.requestTimeout <= Duration.zero) {
      return Future<Map<String, dynamic>>.error(
        const LicoClientRpcException('invalid_timeout'),
      );
    }
    final immutableParams = Map<String, dynamic>.unmodifiable(params);
    return _operations.serialize(
      () =>
          executeStdioRpcStructuredCommand(
            method: method,
            params: immutableParams,
            requestId: _nextRequestId(),
            workflowId: _workflowId,
            sessionManager: _sessionManager,
          ).timeout(
            _processContext.requestTimeout,
            onTimeout: () async {
              await _sessionManager.invalidateAndDiscard();
              throw const LicoClientRpcException('timeout');
            },
          ),
    );
  }

  @override
  Stream<Map<String, dynamic>> streamConversation(Map<String, dynamic> params) {
    if (_processContext.requestTimeout <= Duration.zero) {
      return Stream<Map<String, dynamic>>.error(
        const LicoClientRpcException('invalid_timeout'),
      );
    }
    return _operations.serializeStream(
      operation: () => executeStdioRpcConversation(
        params: params,
        requestId: _nextRequestId(),
        workflowId: _workflowId,
        sessionManager: _sessionManager,
      ),
      timeout: _processContext.requestTimeout,
      onTimeout: _sessionManager.invalidateAndDiscard,
    );
  }

  String _nextRequestId() => 'request-${++_requestSequence}';

  @override
  Future<void> dispose() {
    return _operations.close(() async {
      final session = _sessionManager.takeForShutdown();
      if (session == null) {
        return;
      }
      await shutdownStdioRpcSession(
        session: session,
        requestId: _nextRequestId(),
        workflowId: _workflowId,
      );
    });
  }
}
