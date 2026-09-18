import 'dart:async';
import 'dart:collection';

import '../cache/byte_lru_cache.dart';

/// Work that is useful to a visible frame is dispatched before background
/// preparation, while still yielding after a bounded foreground batch.
enum PreparationPriority { foreground, background }

final class PreparationBackpressureException implements Exception {
  const PreparationBackpressureException({
    required this.maxPendingTasks,
    required this.maxQueuedBytes,
    required this.pendingTasks,
    required this.queuedBytes,
    required this.requestedBytes,
  });

  final int maxPendingTasks;
  final int maxQueuedBytes;
  final int pendingTasks;
  final int queuedBytes;
  final int requestedBytes;

  @override
  String toString() =>
      'PreparationBackpressureException(pending: $pendingTasks/'
      '$maxPendingTasks, bytes: $queuedBytes/$maxQueuedBytes, '
      'requested: $requestedBytes)';
}

typedef PreparationOperation<Value> = FutureOr<Value> Function();

/// A bounded, single-owner preparation executor.
///
/// The default is one worker. [maxWorkers] can be raised by a caller that has
/// measured a useful parallel workload; it is never increased automatically.
/// Foreground tasks are selected for at most [batchSize] consecutive dispatches
/// before one background task gets a turn.
final class BoundedPreparationExecutor {
  BoundedPreparationExecutor({
    int maxWorkers = 1,
    int batchSize = 4,
    int maxPendingTasks = 64,
    int maxQueuedBytes = 4 * 1024 * 1024,
    int maxInFlightBytes = 4 * 1024 * 1024,
  }) : maxWorkers = _positive(maxWorkers, 'maxWorkers'),
       batchSize = _positive(batchSize, 'batchSize'),
       maxPendingTasks = _positive(maxPendingTasks, 'maxPendingTasks'),
       maxQueuedBytes = _positive(maxQueuedBytes, 'maxQueuedBytes'),
       maxInFlightBytes = _positive(maxInFlightBytes, 'maxInFlightBytes'),
       _payloadBudget = ByteBackpressure(capacityBytes: maxInFlightBytes);

  final int maxWorkers;
  final int batchSize;
  final int maxPendingTasks;
  final int maxQueuedBytes;
  final int maxInFlightBytes;
  final ByteBackpressure _payloadBudget;
  final ListQueue<_QueuedTask<Object?>> _foreground =
      ListQueue<_QueuedTask<Object?>>();
  final ListQueue<_QueuedTask<Object?>> _background =
      ListQueue<_QueuedTask<Object?>>();
  final Set<_QueuedTask<Object?>> _active = <_QueuedTask<Object?>>{};
  final List<Completer<void>> _idleWaiters = <Completer<void>>[];
  int _queuedBytes = 0;
  int _inFlightBytes = 0;
  int _foregroundStreak = 0;
  bool _disposed = false;

  int get activeTasks => _active.length;

  int get queuedTasks => _foreground.length + _background.length;

  int get pendingTasks => activeTasks + queuedTasks;

  int get queuedBytes => _queuedBytes;

  int get inFlightBytes => _inFlightBytes;

  bool get disposed => _disposed;

  Future<Value> submit<Value>(
    PreparationOperation<Value> operation, {
    int estimatedBytes = 0,
    PreparationPriority priority = PreparationPriority.foreground,
  }) {
    if (_disposed) return Future<Value>.error(StateError('executor disposed'));
    if (estimatedBytes < 0) {
      return Future<Value>.error(
        ArgumentError.value(
          estimatedBytes,
          'estimatedBytes',
          'must not be negative',
        ),
      );
    }
    if (estimatedBytes > maxInFlightBytes ||
        pendingTasks >= maxPendingTasks ||
        _queuedBytes + _inFlightBytes + estimatedBytes > maxQueuedBytes) {
      return Future<Value>.error(
        PreparationBackpressureException(
          maxPendingTasks: maxPendingTasks,
          maxQueuedBytes: maxQueuedBytes,
          pendingTasks: pendingTasks,
          queuedBytes: _queuedBytes + _inFlightBytes,
          requestedBytes: estimatedBytes,
        ),
      );
    }

    final task = _QueuedTask<Value>(
      operation: operation,
      estimatedBytes: estimatedBytes,
    );
    _queuedBytes += estimatedBytes;
    switch (priority) {
      case PreparationPriority.foreground:
        _foreground.add(task as _QueuedTask<Object?>);
      case PreparationPriority.background:
        _background.add(task as _QueuedTask<Object?>);
    }
    _pump();
    return task.completer.future;
  }

  /// Completes when all accepted tasks have reached a terminal state.
  Future<void> get idle {
    if (pendingTasks == 0) return Future<void>.value();
    final waiter = Completer<void>();
    _idleWaiters.add(waiter);
    return waiter.future;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    final error = StateError('executor disposed before task admission');
    for (final task in <_QueuedTask<Object?>>[..._foreground, ..._background]) {
      task.completer.completeError(error, StackTrace.current);
    }
    _foreground.clear();
    _background.clear();
    _queuedBytes = 0;
    _completeIdleIfReady();
  }

  void _pump() {
    while (!_disposed && _active.length < maxWorkers) {
      final task = _takeRunnable();
      if (task == null) break;
      _active.add(task);
      _queuedBytes -= task.estimatedBytes;
      _inFlightBytes += task.estimatedBytes;
      final permit = _payloadBudget.acquire(task.estimatedBytes);
      final future = Future<Object?>.sync(task.operation);
      future.then<void>(
        (value) {
          task.completer.complete(value);
          _finish(task, permit);
        },
        onError: (Object error, StackTrace stack) {
          task.completer.completeError(error, stack);
          _finish(task, permit);
        },
      );
    }
  }

  _QueuedTask<Object?>? _takeRunnable() {
    final hasForeground = _foreground.isNotEmpty;
    final hasBackground = _background.isNotEmpty;
    if (!hasForeground && !hasBackground) return null;

    final preferBackground =
        hasBackground && (!hasForeground || _foregroundStreak >= batchSize);
    final preferred = preferBackground ? _background : _foreground;
    final alternate = preferBackground ? _foreground : _background;

    final first = preferred.isEmpty ? null : preferred.removeFirst();
    if (first != null && _fits(first)) {
      if (identical(preferred, _foreground)) {
        _foregroundStreak++;
      } else {
        _foregroundStreak = 0;
      }
      return first;
    }
    if (first != null) preferred.addFirst(first);

    final second = alternate.isEmpty ? null : alternate.removeFirst();
    if (second != null && _fits(second)) {
      if (identical(alternate, _foreground)) {
        _foregroundStreak++;
      } else {
        _foregroundStreak = 0;
      }
      return second;
    }
    if (second != null) alternate.addFirst(second);
    return null;
  }

  bool _fits(_QueuedTask<Object?> task) =>
      _inFlightBytes + task.estimatedBytes <= maxInFlightBytes;

  void _finish(_QueuedTask<Object?> task, BytePermit permit) {
    if (!_active.remove(task)) return;
    _inFlightBytes -= task.estimatedBytes;
    permit.release();
    _pump();
    _completeIdleIfReady();
  }

  void _completeIdleIfReady() {
    if (pendingTasks != 0) return;
    for (final waiter in _idleWaiters) {
      if (!waiter.isCompleted) waiter.complete();
    }
    _idleWaiters.clear();
  }

  static int _positive(int value, String name) {
    if (value <= 0) throw ArgumentError.value(value, name, 'must be positive');
    return value;
  }
}

typedef PreparationExecutor = BoundedPreparationExecutor;

final class _QueuedTask<Value> {
  _QueuedTask({required this.operation, required this.estimatedBytes});

  final PreparationOperation<Value> operation;
  final int estimatedBytes;
  final Completer<Value> completer = Completer<Value>();
}
