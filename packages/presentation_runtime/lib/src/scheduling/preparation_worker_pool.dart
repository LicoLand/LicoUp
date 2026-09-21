import 'dart:async';
import 'dart:collection';
import 'dart:io' show Platform;

import 'preparation_cancellation.dart';
import 'preparation_executor.dart'
    show PreparationPriority, PreparationBackpressureException;
import 'preparation_worker.dart';

/// Result of sizing a pool from measured throughput.
///
/// The count is never a constant someone named: it is the candidate that
/// actually finished the probe workload fastest on this machine, bounded by the
/// machine's parallelism and by the caller's ceiling.
final class WorkerConcurrencyMeasurement {
  const WorkerConcurrencyMeasurement({
    required this.workers,
    required this.selectedElapsed,
    required this.candidates,
    required this.measuredElapsed,
    required this.cpuCount,
  });

  /// Worker count the pool was sized to.
  final int workers;

  /// Wall time of the selected candidate over the probe workload.
  final Duration selectedElapsed;

  /// Candidates the probe considered, in order.
  final List<int> candidates;

  /// Measured wall time per candidate that ran.
  final Map<int, Duration> measuredElapsed;

  /// Processors this machine reports.
  final int cpuCount;

  /// True when the probe kept the smallest candidate because more workers did
  /// not finish the probe workload sooner.
  bool get parallelismDidNotHelp =>
      workers == candidates.first && candidates.length > 1;

  @override
  String toString() =>
      'WorkerConcurrencyMeasurement(workers: $workers, '
      'elapsed: ${selectedElapsed.inMicroseconds}us, measured: $measuredElapsed, '
      'cpus: $cpuCount)';
}

/// A pool of real worker isolates shared by all preparations of one runtime.
///
/// Work is dispatched to the least loaded worker; each worker runs one job at a
/// time. The pool never runs a job on the calling isolate.
final class PreparationWorkerPool {
  PreparationWorkerPool._(this._workers, this.measurement, this.name)
    : _load = List<int>.filled(_workers.length, 0);

  final List<PreparationWorker> _workers;
  final List<int> _load;
  final String name;
  final ListQueue<_QueuedExecution> _foreground = ListQueue<_QueuedExecution>();
  final ListQueue<_QueuedExecution> _background = ListQueue<_QueuedExecution>();
  int _pendingBytes = 0;
  int _foregroundStreak = 0;
  static const int _foregroundTurn = 4;
  final int maxPendingJobs = 64;
  final int maxPendingBytes = 4 * 1024 * 1024;
  bool _disposed = false;

  /// How the worker count was chosen. Null when the caller fixed the count.
  final WorkerConcurrencyMeasurement? measurement;

  /// Spawns a pool with an explicit worker count.
  static Future<PreparationWorkerPool> spawn({
    required String name,
    required Map<String, PreparationWorkerOperation> operations,
    int workers = 1,
  }) async {
    if (workers < 1) {
      throw ArgumentError.value(workers, 'workers', 'must be positive');
    }
    final spawned = <PreparationWorker>[];
    for (var index = 0; index < workers; index++) {
      try {
        spawned.add(
          await PreparationWorker.spawn(
            name: name,
            workerId: index,
            operations: operations,
          ),
        );
      } catch (_) {
        // A worker that failed to come up must not leave its siblings running
        // with nothing owning them.
        for (final worker in spawned) {
          await worker.dispose();
        }
        rethrow;
      }
    }
    return PreparationWorkerPool._(spawned, null, name);
  }

  /// Spawns a pool whose worker count comes from a real throughput probe.
  ///
  /// [workloadOperation] must be one of [operations]; [workloadPayload] is the
  /// probe input and [probeJobs] the number of jobs each candidate runs. The
  /// probe measures the same CPU work the pool will really execute, so a
  /// machine where a second worker does not help keeps the smaller pool.
  static Future<PreparationWorkerPool> spawnMeasured({
    required String name,
    required Map<String, PreparationWorkerOperation> operations,
    required String workloadOperation,
    required Object? workloadPayload,
    int probeJobs = 4,
    int maxCandidates = 4,
  }) async {
    if (!operations.containsKey(workloadOperation)) {
      throw ArgumentError.value(
        workloadOperation,
        'workloadOperation',
        'must be one of the provided operations',
      );
    }
    if (probeJobs < 1) {
      throw ArgumentError.value(probeJobs, 'probeJobs', 'must be positive');
    }
    final candidates = candidateCounts(maxCandidates);
    final measured = <int, Duration>{};
    int? best;
    Duration? bestElapsed;
    for (final candidate in candidates) {
      final probe = await PreparationWorkerPool.spawn(
        name: '$name-probe',
        operations: operations,
        workers: candidate,
      );
      final watch = Stopwatch()..start();
      try {
        await Future.wait<void>(<Future<void>>[
          for (var index = 0; index < probeJobs; index++)
            probe
                .execute(operation: workloadOperation, payload: workloadPayload)
                .then((_) {}),
        ]);
      } finally {
        watch.stop();
        // A probe pool is a measurement device, not a result: it is released
        // whether the probe workload finished or failed.
        await probe.dispose();
      }
      measured[candidate] = watch.elapsed;
      if (bestElapsed == null || watch.elapsed < bestElapsed) {
        bestElapsed = watch.elapsed;
        best = candidate;
      }
    }
    final chosen = best ?? candidates.first;
    final pool = await PreparationWorkerPool.spawn(
      name: name,
      operations: operations,
      workers: chosen,
    );
    return PreparationWorkerPool._(
      pool._workers,
      WorkerConcurrencyMeasurement(
        workers: chosen,
        selectedElapsed: bestElapsed ?? Duration.zero,
        candidates: candidates,
        measuredElapsed: Map<int, Duration>.unmodifiable(measured),
        cpuCount: Platform.numberOfProcessors,
      ),
      name,
    );
  }

  /// Candidate worker counts for this machine, smallest first.
  static List<int> candidateCounts(int maxCandidates) {
    if (maxCandidates < 1) {
      throw ArgumentError.value(
        maxCandidates,
        'maxCandidates',
        'must be positive',
      );
    }
    final available = Platform.numberOfProcessors;
    final count = available < maxCandidates ? available : maxCandidates;
    return <int>[for (var workers = 1; workers <= count; workers++) workers];
  }

  /// Identity of every worker in this pool, reported by each isolate itself.
  List<PreparationWorkerIdentity> get identities =>
      List<PreparationWorkerIdentity>.unmodifiable(<PreparationWorkerIdentity>[
        for (final worker in _workers) worker.identity,
      ]);

  int get workers => _workers.length;

  bool get disposed => _disposed;

  /// Jobs accepted but not yet settled.
  int get pendingJobs => _foreground.length + _background.length + _inFlight;

  int get _inFlight =>
      _load.fold<int>(0, (sum, value) => sum + (value > 0 ? value : 0));

  /// Worker-isolate counters summed across the pool.
  WorkerExecutionStats get workerStats {
    var handled = 0;
    var dropped = 0;
    var aborted = 0;
    var yields = 0;
    var workBytes = 0;
    for (final worker in _workers) {
      final stats = worker.workerStats;
      handled += stats.handled;
      dropped += stats.droppedWhileQueued;
      aborted += stats.abortedMidJob;
      yields += stats.yields;
      workBytes += stats.workBytes;
    }
    return WorkerExecutionStats(
      handled: handled,
      droppedWhileQueued: dropped,
      abortedMidJob: aborted,
      yields: yields,
      workBytes: workBytes,
    );
  }

  /// Executes one operation on the least loaded worker.
  ///
  /// Foreground work is dispatched before background work, so a visible frame
  /// never queues behind speculative preparation.
  Future<Object?> execute({
    required String operation,
    Object? payload,
    PreparationCancellationToken? cancel,
    PreparationPriority priority = PreparationPriority.foreground,
    void Function(PreparationWorkerIdentity identity)? onWorker,
    int estimatedBytes = 0,
  }) {
    if (_disposed) {
      return Future<Object?>.error(
        const PreparationWorkerClosedException('worker pool disposed'),
      );
    }
    final requested = cancel?.reason;
    if (requested != null) {
      return Future<Object?>.error(
        PreparationCancelledException(requested, stage: 'queued'),
      );
    }
    if (estimatedBytes < 0) {
      return Future<Object?>.error(ArgumentError.value(estimatedBytes));
    }
    if (pendingJobs >= maxPendingJobs ||
        _pendingBytes + estimatedBytes > maxPendingBytes) {
      return Future<Object?>.error(
        PreparationBackpressureException(
          maxPendingTasks: maxPendingJobs,
          maxQueuedBytes: maxPendingBytes,
          pendingTasks: pendingJobs,
          queuedBytes: _pendingBytes,
          requestedBytes: estimatedBytes,
        ),
      );
    }
    final queued = _QueuedExecution(
      operation: operation,
      payload: payload,
      cancel: cancel,
      priority: priority,
      onWorker: onWorker,
      estimatedBytes: estimatedBytes,
    );
    _pendingBytes += estimatedBytes;
    void onCancel(PreparationCancellationReason reason) {
      if (_foreground.remove(queued) || _background.remove(queued)) {
        _pendingBytes -= queued.estimatedBytes;
        queued.detach?.call();
        queued.completer.completeError(
          PreparationCancelledException(reason, stage: 'queued'),
        );
      }
    }

    queued.detach = () => cancel?.removeListener(onCancel);
    cancel?.addListener(onCancel);
    switch (priority) {
      case PreparationPriority.foreground:
        _foreground.add(queued);
      case PreparationPriority.background:
        _background.add(queued);
    }
    _dispatch();
    return queued.completer.future;
  }

  /// Completes once every accepted job has settled.
  Future<void> get idle async {
    while (pendingJobs > 0) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    const failure = PreparationWorkerClosedException('worker pool disposed');
    for (final queued in <_QueuedExecution>[..._foreground, ..._background]) {
      queued.detach?.call();
      _pendingBytes -= queued.estimatedBytes;
      if (!queued.completer.isCompleted) {
        queued.completer.completeError(failure, StackTrace.current);
      }
    }
    _foreground.clear();
    _background.clear();
    await Future.wait<void>([for (final worker in _workers) worker.dispose()]);
  }

  void _dispatch() {
    while (!_disposed && (_foreground.isNotEmpty || _background.isNotEmpty)) {
      final index = _leastLoaded();
      if (_load[index] != 0) break;
      final useBackground =
          _background.isNotEmpty &&
          (_foreground.isEmpty || _foregroundStreak >= _foregroundTurn);
      final queued = useBackground
          ? _background.removeFirst()
          : _foreground.removeFirst();
      _foregroundStreak = useBackground ? 0 : _foregroundStreak + 1;
      queued.detach?.call();
      _load[index]++;
      queued.workerIndex = index;
      var released = false;
      void release() {
        if (released) return;
        released = true;
        _load[index]--;
        _pendingBytes -= queued.estimatedBytes;
        _dispatch();
      }

      Future<Object?>.sync(() {
        queued.onWorker?.call(_workers[index].identity);
        return _workers[index].execute(
          operation: queued.operation,
          payload: queued.payload,
          cancel: queued.cancel,
          onReleased: release,
        );
      }).then<void>(
        (value) => _settle(queued, value, null),
        onError: (Object error, StackTrace stack) {
          // Cancellation of running work releases capacity only when the
          // worker acknowledges it, not when the caller stops waiting.
          if (error is! PreparationCancelledException ||
              error.stage == 'queued')
            release();
          _settle(queued, null, error);
        },
      );
    }
  }

  void _settle(_QueuedExecution queued, Object? value, Object? error) {
    if (!queued.completer.isCompleted) {
      if (error == null) {
        queued.completer.complete(value);
      } else {
        queued.completer.completeError(error, StackTrace.current);
      }
    }
    _dispatch();
  }

  int _leastLoaded() {
    var best = 0;
    for (var index = 1; index < _load.length; index++) {
      if (_load[index] < _load[best]) best = index;
    }
    return best;
  }
}

final class _QueuedExecution {
  _QueuedExecution({
    required this.operation,
    required this.payload,
    required this.cancel,
    required this.priority,
    required this.onWorker,
    required this.estimatedBytes,
  });

  final String operation;
  final int estimatedBytes;
  void Function()? detach;
  final Object? payload;
  final PreparationCancellationToken? cancel;
  final PreparationPriority priority;
  final void Function(PreparationWorkerIdentity identity)? onWorker;
  final Completer<Object?> completer = Completer<Object?>();
  int workerIndex = -1;
}
