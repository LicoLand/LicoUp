import 'dart:async';

import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc/operation_pending_queue.dart';
import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc/session_manager.dart';
import 'package:licoup/src/platform/native_client/native_cli_ports.dart';
import 'package:licoup/src/platform/native_client/native_rpc_priority.dart';

typedef _ReadOperation = Future<void> Function(StdioRpcSessionManager);

/// Reuses a bounded number of independent native query sessions. Pending work
/// is assigned when any session becomes available, so a slow query cannot hold
/// an idle peer behind it. Results are never cached by the transport.
final class StdioRpcReadPool {
  StdioRpcReadPool({required NativeCliProcessContext processContext})
    : _processContext = processContext;

  // Each session owns one native sidecar. Keep startup and retained native
  // memory bounded while allowing independent feature reads to overlap.
  static const int capacity = 4;

  final NativeCliProcessContext _processContext;
  final RpcOperationPendingQueue<_ReadOperation> _pending =
      RpcOperationPendingQueue<_ReadOperation>();
  final List<_ReadWorker> _workers = [];
  Future<void>? _closeFuture;

  Future<T> execute<T>(
    Future<T> Function(StdioRpcSessionManager) operation, {
    RpcPriorityToken? priority,
  }) {
    if (_closeFuture != null) {
      return Future<T>.error(const LicoClientRpcException('service_disposed'));
    }
    final result = Completer<T>();
    _pending.add((manager) async {
      try {
        result.complete(await operation(manager));
      } on Object catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      }
    }, priority: priority);
    var worker = _workers.where((worker) => worker.running == null).firstOrNull;
    if (worker == null && _workers.length < capacity) {
      worker = _ReadWorker(
        StdioRpcSessionManager(processContext: _processContext),
      );
      _workers.add(worker);
    }
    if (worker != null) {
      worker.running = _drain(worker);
    }
    return result.future;
  }

  Future<void> _drain(_ReadWorker worker) async {
    while (!_pending.isEmpty) {
      await _pending.takeNext()(worker.manager);
    }
    worker.running = null;
  }

  /// Rejects new reads, lets accepted reads settle, and closes each idle
  /// session immediately. A busy peer does not delay another peer's shutdown.
  Future<void> close(Future<void> Function(StdioRpcSessionManager) shutdown) {
    final existing = _closeFuture;
    if (existing != null) return existing;
    final closed = Completer<void>();
    _closeFuture = closed.future;
    Future<void> closeWorker(_ReadWorker worker) async {
      await worker.running;
      try {
        await shutdown(worker.manager);
      } on Object catch (_) {}
    }

    Future.wait(_workers.map(closeWorker)).then((_) => closed.complete());
    return closed.future;
  }
}

final class _ReadWorker {
  _ReadWorker(this.manager);

  final StdioRpcSessionManager manager;
  Future<void>? running;
}
