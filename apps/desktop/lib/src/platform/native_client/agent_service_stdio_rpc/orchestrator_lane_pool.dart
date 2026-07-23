import 'package:flutter_client/src/platform/native_client/agent_service_stdio_rpc/command_exchange.dart';
import 'package:flutter_client/src/platform/native_client/agent_service_stdio_rpc/operation_queue.dart';
import 'package:flutter_client/src/platform/native_client/agent_service_stdio_rpc/session_manager.dart';
import 'package:flutter_client/src/platform/native_client/agent_service_stdio_rpc/shutdown.dart';
import 'package:flutter_client/src/platform/native_client/native_cli_ports.dart';
import 'package:flutter_client/src/platform/native_client/native_rpc_priority.dart';

/// Lazy bounded lanes for the Local Bridge control plane.
///
/// Commands for one workflow remain ordered, while unrelated workflows can
/// progress concurrently. Long-poll waits use a separate pool so they never
/// occupy the lane that must deliver the message which wakes them.
final class StdioRpcOrchestratorLanePool {
  StdioRpcOrchestratorLanePool({
    required NativeCliProcessContext processContext,
    required String Function() nextRequestId,
    required String Function() workflowId,
  }) : _processContext = processContext,
       _nextRequestId = nextRequestId,
       _workflowId = workflowId,
       _commandLanes = List<_OrchestratorLane>.generate(
         _laneCount,
         (_) => _OrchestratorLane(processContext),
         growable: false,
       ),
       _waitLanes = List<_OrchestratorLane>.generate(
         _laneCount,
         (_) => _OrchestratorLane(processContext),
         growable: false,
       );

  static const int _laneCount = 8;

  final NativeCliProcessContext _processContext;
  final String Function() _nextRequestId;
  final String Function() _workflowId;
  final List<_OrchestratorLane> _commandLanes;
  final List<_OrchestratorLane> _waitLanes;

  Future<Map<String, dynamic>> execute(Map<String, dynamic> params) {
    final lane = _laneFor(params);
    final timeout = _requestTimeout(params);
    return lane.operations.serialize(
      priority: currentRpcPriorityToken(),
      () =>
          executeStdioRpcStructuredCommand(
            method: 'orchestrator.request',
            params: params,
            requestId: _nextRequestId(),
            workflowId: _workflowId(),
            sessionManager: lane.sessionManager,
          ).timeout(
            timeout,
            onTimeout: () async {
              await lane.sessionManager.invalidateAndDiscard();
              throw const LicoClientRpcException('timeout');
            },
          ),
    );
  }

  Future<void> dispose() async {
    await Future.wait<void>([
      for (final lane in _commandLanes)
        lane.operations.close(() => _shutdown(lane.sessionManager)),
      for (final lane in _waitLanes)
        lane.operations.close(() => _shutdown(lane.sessionManager)),
    ]);
  }

  _OrchestratorLane _laneFor(Map<String, dynamic> params) {
    final lanes = params['method'] == 'workflow.wait'
        ? _waitLanes
        : _commandLanes;
    final body = params['params'];
    final scope = body is Map
        ? (body['workflowId'] ??
                  body['policyRevisionId'] ??
                  params['idempotencyKey'] ??
                  params['method'] ??
                  '')
              .toString()
        : (params['idempotencyKey'] ?? params['method'] ?? '').toString();
    var hash = 0x811c9dc5;
    for (final codeUnit in scope.codeUnits) {
      hash = ((hash ^ codeUnit) * 0x01000193) & 0x7fffffff;
    }
    return lanes[hash % lanes.length];
  }

  Duration _requestTimeout(Map<String, dynamic> params) {
    if (params['method'] != 'workflow.wait') {
      return _processContext.requestTimeout;
    }
    final body = params['params'];
    final rawTimeout = body is Map ? body['timeoutMs'] : null;
    final requestedMs = rawTimeout is num ? rawTimeout.toInt() : 0;
    final timeoutMs = requestedMs < 0
        ? 0
        : requestedMs > 30000
        ? 30000
        : requestedMs;
    final waitTimeout = Duration(milliseconds: timeoutMs + 2000);
    return waitTimeout > _processContext.requestTimeout
        ? waitTimeout
        : _processContext.requestTimeout;
  }

  Future<void> _shutdown(StdioRpcSessionManager manager) async {
    await shutdownStdioRpcManager(
      manager: manager,
      requestId: _nextRequestId(),
      workflowId: _workflowId(),
    );
  }
}

final class _OrchestratorLane {
  _OrchestratorLane(NativeCliProcessContext processContext)
    : sessionManager = StdioRpcSessionManager(processContext: processContext);

  final StdioRpcSessionManager sessionManager;
  final StdioRpcOperationQueue operations = StdioRpcOperationQueue();
}
