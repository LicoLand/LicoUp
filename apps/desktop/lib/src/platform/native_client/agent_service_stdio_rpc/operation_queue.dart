import 'dart:async';

import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc/operation_pending_queue.dart';
import 'package:licoup/src/platform/native_client/native_cli_ports.dart';
import 'package:licoup/src/platform/native_client/native_rpc_priority.dart';

typedef RpcOp<T> = Future<T> Function();

const _timeoutError = LicoClientRpcException('timeout');

/// Serializes commands, streams, and shutdown for one stdio session.
final class StdioRpcOperationQueue {
  final RpcOperationPendingQueue _pending = RpcOperationPendingQueue();
  var _running = false, _closing = false;
  Future<void>? _closeFuture;

  bool get closing => _closing;

  Future<T> serialize<T>(RpcOp<T> operation, {RpcPriorityToken? priority}) {
    if (_closing) {
      return Future<T>.error(const LicoClientRpcException('service_disposed'));
    }
    final completer = Completer<T>();
    _enqueue(() async {
      try {
        completer.complete(await operation());
      } on Object catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    }, priority);
    return completer.future;
  }

  Stream<T> serializeStream<T>({
    required Stream<T> Function() operation,
    Duration? timeout,
    required Future<void> Function() onTimeout,
  }) {
    if (_closing) {
      return Stream<T>.error(const LicoClientRpcException('service_disposed'));
    }
    final controller = StreamController<T>();
    _enqueue(() async {
      try {
        final events = operation();
        // A null timeout keeps the operation unbounded (agent turns run until
        // they complete, however long that takes).
        await for (final event
            in timeout == null ? events : events.timeout(timeout)) {
          controller.add(event);
        }
      } on TimeoutException catch (_, stackTrace) {
        await onTimeout();
        controller.addError(_timeoutError, stackTrace);
      } on Object catch (error, stackTrace) {
        controller.addError(error, stackTrace);
      } finally {
        await controller.close();
      }
    });
    return controller.stream;
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
  /// The native conversation host remains responsible for active Agent work.
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

  void _enqueue(RpcOp<void> run, [RpcPriorityToken? priority]) {
    _pending.add(run, priority: priority);
    if (_running) return;
    _running = true;
    unawaited(_drain());
  }

  Future<void> _drain() async {
    while (!_pending.isEmpty) {
      try {
        await _pending.takeNext()();
      } on Object catch (_) {}
    }
    _running = false;
  }
}
