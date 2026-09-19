import 'dart:async';

import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc/operation_pending_queue.dart';
import 'package:licoup/src/platform/native_client/native_cli_ports.dart';
import 'package:licoup/src/platform/native_client/native_rpc_priority.dart';

typedef RpcOp<T> = Future<T> Function();

/// Serializes bounded commands and shutdown for one stdio session. Unbounded
/// PersistentTurn observers are multiplexed by the session itself and never
/// occupy this queue.
final class StdioRpcOperationQueue {
  final RpcOperationPendingQueue<RpcOp<void>> _pending =
      RpcOperationPendingQueue<RpcOp<void>>();
  var _running = false, _closing = false;
  Future<void>? _closeFuture;

  bool get closing => _closing;
  int get pendingCount => _pending.length;
  int get pendingPayloadBytes => _pending.totalPayloadBytes;
  bool get hasBackpressure => _pending.hasBackpressure;

  Future<T> serialize<T>(
    RpcOp<T> operation, {
    RpcPriorityToken? priority,
    int byteSize = 0,
    void Function(RpcPendingEntryHandle<RpcOp<void>> handle)? onEnqueued,
  }) {
    if (_closing) {
      return Future<T>.error(const LicoClientRpcException('service_disposed'));
    }
    final completer = Completer<T>();
    final handle = _enqueue(
      () async {
        try {
          completer.complete(await operation());
        } on Object catch (error, stackTrace) {
          completer.completeError(error, stackTrace);
        }
      },
      priority: priority,
      byteSize: byteSize,
      onCancelled: () {
        if (!completer.isCompleted) {
          completer.completeError(const LicoClientRpcException('cancelled'));
        }
      },
    );
    onEnqueued?.call(handle);
    return completer.future;
  }

  Future<void> close(Future<void> Function() shutdown) {
    final existing = _closeFuture;
    if (existing != null) return existing;
    _closing = true;
    final completer = Completer<void>();
    _enqueue(() async {
      try {
        await shutdown();
      } on Object catch (_) {}
      completer.complete();
    });
    return _closeFuture = completer.future;
  }

  /// Stops accepting work and releases the observer transport immediately.
  /// The conversation host still belongs to this LicoUp process and exits
  /// when that process is gone.
  Future<void> detach(Future<void> Function() detachTransport) {
    final existing = _closeFuture;
    if (existing != null) return existing;
    _closing = true;
    final completer = Completer<void>();
    _closeFuture = completer.future;
    Future<void> releaseTransport() async {
      try {
        await detachTransport();
      } on Object catch (_) {
      } finally {
        completer.complete();
      }
    }

    unawaited(releaseTransport());
    return completer.future;
  }

  RpcPendingEntryHandle<RpcOp<void>> _enqueue(
    RpcOp<void> run, {
    RpcPriorityToken? priority,
    int byteSize = 0,
    void Function()? onCancelled,
  }) {
    final handle = _pending.add(
      run,
      priority: priority,
      byteSize: byteSize,
      onCancelled: onCancelled,
    );
    if (_running) return handle;
    _running = true;
    unawaited(_drain());
    return handle;
  }

  Future<void> _drain() async {
    try {
      while (_pending.isNotEmpty) {
        try {
          await _pending.takeNext()();
        } on Object catch (_) {}
      }
    } finally {
      _running = false;
    }
  }
}
