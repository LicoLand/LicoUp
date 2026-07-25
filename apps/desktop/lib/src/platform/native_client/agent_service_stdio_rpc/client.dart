import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc/command_exchange.dart';
import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc/conversation_exchange.dart';
import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc/method_policy.dart';
import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc/operation_queue.dart';
import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc/orchestrator_lane_pool.dart';
import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc/protocol.dart';
import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc/session_manager.dart';
import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc/shutdown.dart';
import 'package:licoup/src/platform/native_client/native_cli_ports.dart';
import 'package:licoup/src/platform/native_client/native_rpc_priority.dart';

class NativeStdioRpcClient implements NativeStdioRpcTransport {
  NativeStdioRpcClient({required NativeCliProcessContext processContext})
    : _processContext = processContext,
      _sessionManager = StdioRpcSessionManager(processContext: processContext),
      _conversationSessionManager = StdioRpcSessionManager(
        processContext: processContext,
      ) {
    _orchestrator = StdioRpcOrchestratorLanePool(
      processContext: processContext,
      nextRequestId: _nextRequestId,
      workflowId: () => _workflowId,
    );
  }

  final NativeCliProcessContext _processContext;
  final StdioRpcSessionManager _sessionManager;
  final StdioRpcSessionManager _conversationSessionManager;
  late final StdioRpcOrchestratorLanePool _orchestrator;
  final StdioRpcOperationQueue _operations = StdioRpcOperationQueue();
  final StdioRpcOperationQueue _conversationOperations =
      StdioRpcOperationQueue();
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
    if (stdioRpcMethodUsesOrchestrator(method)) {
      return _orchestrator.execute(immutableParams);
    }
    final conversationMethod = stdioRpcMethodUsesConversationLane(method);
    final operations = conversationMethod
        ? _conversationOperations
        : _operations;
    final sessionManager = conversationMethod
        ? _conversationSessionManager
        : _sessionManager;
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
        sessionManager: _conversationSessionManager,
      ),
      timeout: _processContext.requestTimeout,
      onTimeout: _conversationSessionManager.invalidateAndDiscard,
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
          manager: _conversationSessionManager,
          requestId: _nextRequestId(),
          workflowId: _workflowId,
        ),
      ),
      _orchestrator.dispose(),
    ]);
  }
}
