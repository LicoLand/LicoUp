import 'dart:async';

import 'package:flutter_client/src/platform/native_client/native_cli_ports.dart';

/// Serializes commands, conversation streams, and shutdown for one stdio
/// session without owning any protocol or process behavior.
final class StdioRpcOperationQueue {
  Future<void> _tail = Future<void>.value();
  Future<void>? _closeFuture;
  var _closing = false;

  bool get closing => _closing;

  Future<T> serialize<T>(Future<T> Function() operation) {
    if (_closing) {
      return Future<T>.error(const LicoClientRpcException('service_disposed'));
    }
    final result = _tail.then<T>((_) => operation());
    _tail = result.then<void>((_) {}, onError: _ignoreError);
    return result;
  }

  Stream<T> serializeStream<T>({
    required Stream<T> Function() operation,
    required Duration timeout,
    required Future<void> Function() onTimeout,
  }) {
    if (_closing) {
      return Stream<T>.error(const LicoClientRpcException('service_disposed'));
    }
    final controller = StreamController<T>();
    final previous = _tail;
    final completed = Completer<void>();
    _tail = previous
        .then<void>((_) => completed.future)
        .then<void>((_) {}, onError: _ignoreError);
    unawaited(() async {
      try {
        await previous;
        await for (final event in operation().timeout(timeout)) {
          controller.add(event);
        }
      } on TimeoutException catch (_, stackTrace) {
        await onTimeout();
        controller.addError(
          const LicoClientRpcException('timeout'),
          stackTrace,
        );
      } on Object catch (error, stackTrace) {
        controller.addError(error, stackTrace);
      } finally {
        await controller.close();
        if (!completed.isCompleted) completed.complete();
      }
    }());
    return controller.stream;
  }

  Future<void> close(Future<void> Function() shutdown) {
    final existing = _closeFuture;
    if (existing != null) return existing;
    _closing = true;
    final result = _tail.then<void>((_) => shutdown());
    _closeFuture = result.then<void>((_) {}, onError: _ignoreError);
    _tail = _closeFuture!;
    return _closeFuture!;
  }

  static void _ignoreError(Object _, StackTrace _) {}
}
