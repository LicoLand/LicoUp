import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc/command_exchange.dart';
import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc/conversation_exchange.dart';
import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc/in_flight_control.dart';
import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc/method_policy.dart';
import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc/operation_queue.dart';
import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc/protocol.dart';
import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc/session_manager.dart';
import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc/shutdown.dart';
import 'package:licoup/src/platform/native_client/native_cli_ports.dart';
import 'package:licoup/src/platform/native_client/native_rpc_priority.dart';

Future<Map<String, dynamic>> _rpcFailure(String code) =>
    Future<Map<String, dynamic>>.error(LicoClientRpcException(code));

class NativeStdioRpcClient implements NativeStdioRpcTransport {
  NativeStdioRpcClient({required NativeCliProcessContext processContext})
    : _processContext = processContext,
      _sessionManager = StdioRpcSessionManager(processContext: processContext),
      _chat = StdioRpcSessionManager(processContext: processContext);

  final NativeCliProcessContext _processContext;
  final StdioRpcSessionManager _sessionManager;
  final StdioRpcSessionManager _chat;
  final StdioRpcOperationQueue _operations = StdioRpcOperationQueue();
  final StdioRpcOperationQueue _conversationOperations =
      StdioRpcOperationQueue();
  late final String _workflowId = newStdioRpcWorkflowId();
  var _requestSequence = 0;

  @override
  Future<Map<String, dynamic>> execute(List<String> args) {
    if (_operations.closing) {
      return _rpcFailure('service_disposed');
    }
    if (_processContext.requestTimeout <= Duration.zero) {
      return _rpcFailure('invalid_timeout');
    }
    if (!validStdioRpcArgs(args)) {
      return _rpcFailure('invalid_request');
    }
    final requestArgs = List<String>.unmodifiable(args);
    return _operations.serialize(
      priority: currentRpcPriorityToken(),
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
    if (_operations.closing || !validStdioRpcStructuredMethod(method)) {
      return _rpcFailure('invalid_request');
    }
    if (_processContext.requestTimeout <= Duration.zero) {
      return _rpcFailure('invalid_timeout');
    }
    final immutableParams = Map<String, dynamic>.unmodifiable(params);
    final conversationMethod = stdioRpcMethodUsesConversationLane(method);
    if (conversationMethod && stdioRpcMethodIsInFlightControl(method)) {
      return executeStdioRpcInFlightControl(
        method: method,
        params: immutableParams,
        requestId: _nextRequestId(),
        workflowId: _workflowId,
        timeout: _processContext.requestTimeout,
        sessionManager: _chat,
      );
    }
    final operations = conversationMethod
        ? _conversationOperations
        : _operations;
    final sessionManager = conversationMethod ? _chat : _sessionManager;
    return operations.serialize(
      priority: currentRpcPriorityToken(),
      () =>
          executeStdioRpcStructuredCommand(
            method: method,
            params: immutableParams,
            requestId: _nextRequestId(),
            workflowId: _workflowId,
            sessionManager: sessionManager,
          ).timeout(
            _processContext.requestTimeout,
            onTimeout: () async {
              await sessionManager.invalidateAndDiscard();
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
    return _conversationOperations.serializeStream(
      operation: () => executeStdioRpcConversation(
        params: params,
        requestId: _nextRequestId(),
        workflowId: _workflowId,
        sessionManager: _chat,
      ),
      timeout: _processContext.requestTimeout,
      onTimeout: _chat.invalidateAndDiscard,
    );
  }

  String _nextRequestId() => 'request-${++_requestSequence}';

  @override
  Future<void> dispose() async {
    await Future.wait<void>([
      _operations.close(
        () => shutdownStdioRpcManager(
          manager: _sessionManager,
          requestId: _nextRequestId(),
          workflowId: _workflowId,
        ),
      ),
      _conversationOperations.close(
        () => shutdownStdioRpcManager(
          manager: _chat,
          requestId: _nextRequestId(),
          workflowId: _workflowId,
        ),
      ),
    ]);
  }
}
