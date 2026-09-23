import 'dart:async';

import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc/operation_pending_queue.dart';
import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc/session_manager.dart';
import 'package:licoup/src/platform/native_client/native_cli_ports.dart';
import 'package:licoup/src/platform/native_client/native_rpc_priority.dart';

typedef StdioRpcReadOperation = Future<void> Function(StdioRpcSessionManager);

/// Reuses a bounded number of independent native query sessions. Pending work
/// is assigned when any session becomes available, so a slow query cannot hold
/// an idle peer behind it. Results are never cached by the transport.
///
/// Background bulk queries may occupy at most [capacity] - 1 sessions. One
/// session always stays available for foreground work, so a catalog or history
/// backlog cannot starve a read that is needed now, and a cancelled or failed
/// background query cannot leave the pool without usable capacity.
final class StdioRpcReadPool {
  StdioRpcReadPool({required NativeCliProcessContext processContext})
    : _processContext = processContext;

  // Each session owns one native sidecar. Keep startup and retained native
  // memory bounded while allowing independent feature reads to overlap.
  static const int capacity = 4;

  final NativeCliProcessContext _processContext;
  final RpcOperationPendingQueue<StdioRpcReadOperation> _pending =
      RpcOperationPendingQueue<StdioRpcReadOperation>();
  final List<_ReadWorker> _workers = [];
  Future<void>? _closeFuture;
  var _backgroundInFlight = 0;

  int get pendingCount => _pending.length;
  int get pendingPayloadBytes => _pending.totalPayloadBytes;
  bool get hasBackpressure => _pending.hasBackpressure;

  Future<T> execute<T>(
    Future<T> Function(StdioRpcSessionManager) operation, {
    RpcPriorityToken? priority,
    int byteSize = 0,
    void Function(RpcPendingEntryHandle<StdioRpcReadOperation> handle)?
    onEnqueued,
  }) {
    if (_closeFuture != null) {
      return Future<T>.error(const LicoClientRpcException('service_disposed'));
    }
    final result = Completer<T>();
    final handle = _pending.add(
      (manager) async {
        try {
          result.complete(await operation(manager));
        } on Object catch (error, stackTrace) {
          result.completeError(error, stackTrace);
        }
      },
      priority: priority,
      byteSize: byteSize,
      onCancelled: () {
        if (!result.isCompleted) {
          result.completeError(const LicoClientRpcException('cancelled'));
        }
      },
    );
    onEnqueued?.call(handle);
    _pump();
    return result.future;
  }

  /// Assigns pending work to idle sessions. Foreground work is taken first;
  /// background work only while a session stays reserved for foreground.
  void _pump() {
    while (_pending.isNotEmpty) {
      final worker = _idleWorker();
      if (worker == null) return;
      final dispatch = _pending.takeNextEligible(
        // Reserve the last session for foreground work: a pending bulk backlog
        // waits for a free bulk session instead of taking the whole capacity.
        (isBackground) => !isBackground || _backgroundInFlight < capacity - 1,
      );
      if (dispatch == null) return;
      worker.running = _drain(worker, dispatch);
    }
  }

  _ReadWorker? _idleWorker() {
    for (final worker in _workers) {
      if (worker.running == null) return worker;
    }
    if (_workers.length >= capacity) return null;
    final worker = _ReadWorker(
      StdioRpcSessionManager(processContext: _processContext),
    );
    _workers.add(worker);
    return worker;
  }

  /// Runs accepted work on one session while pending work remains, so a session
  /// is shut down only after the reads assigned to it have settled.
  Future<void> _drain(
    _ReadWorker worker,
    ({StdioRpcReadOperation run, bool isBackground}) dispatch,
  ) async {
    try {
      while (true) {
        if (dispatch.isBackground) {
          _backgroundInFlight += 1;
        }
        try {
          await dispatch.run(worker.manager);
        } on Object catch (_) {
        } finally {
          if (dispatch.isBackground) {
            _backgroundInFlight -= 1;
          }
        }
        if (_pending.isEmpty) return;
        final next = _pending.takeNextEligible(
          (isBackground) => !isBackground || _backgroundInFlight < capacity - 1,
        );
        if (next == null) return;
        dispatch = next;
      }
    } finally {
      worker.running = null;
    }
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
