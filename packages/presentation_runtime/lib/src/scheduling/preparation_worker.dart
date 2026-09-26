import 'dart:async';
import 'dart:collection';
import 'dart:isolate';

import 'preparation_cancellation.dart';

/// One operation a worker isolate can execute.
///
/// A handler runs inside the worker isolate. It receives one isolate-sendable
/// payload and returns one isolate-sendable payload. It must not capture
/// renderer state: a worker only ever sees the compact payload it was given.
typedef PreparationWorkerOperation =
    FutureOr<Object?> Function(Object? payload, WorkerJobContext context);

/// Control a running handler is given over its own scheduling.
///
/// A CPU-bound handler cannot be interrupted from outside, so the honest
/// cancellation boundary is a chunk of work the handler chooses to yield after.
/// [yieldToControl] is that boundary: it lets the worker isolate's own event
/// loop run, which is when a cancel or shutdown message can be received.
abstract interface class WorkerJobContext {
  /// True once a cancel message for this job has been received by the worker.
  bool get isCancelled;

  /// Number of yields this job has handed back to the worker's event loop.
  int get yieldCount;

  /// Yields to the worker's event loop without blocking the worker thread.
  Future<void> yieldToControl();

  /// Records input bytes this job consumed, for worker-side accounting.
  void recordWorkBytes(int bytes);
}

/// Identity of one real worker isolate, reported from inside that isolate.
///
/// The values are not constructed by the caller: they are what the worker
/// observed about itself, which is what makes them evidence of a separate
/// execution context rather than a naming convention.
final class PreparationWorkerIdentity {
  const PreparationWorkerIdentity({
    required this.name,
    required this.workerId,
    required this.isolateDebugName,
    required this.controlPort,
  });

  /// Label given to this worker at spawn time.
  final String name;

  /// Process-local ordinal of this worker inside its pool.
  final int workerId;

  /// `Isolate.current.debugName` as reported by the worker itself.
  final String isolateDebugName;

  /// `Isolate.current.controlPort` as reported by the worker itself.
  final SendPort controlPort;

  /// True when the isolate answering this question is the worker itself.
  ///
  /// Evaluated in the calling isolate, so a real worker answers false and a
  /// placeholder local executor would answer true.
  bool get runsInCallerIsolate => controlPort == Isolate.current.controlPort;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PreparationWorkerIdentity &&
          other.name == name &&
          other.workerId == workerId &&
          other.isolateDebugName == isolateDebugName &&
          other.controlPort == controlPort;

  @override
  int get hashCode =>
      Object.hash(name, workerId, isolateDebugName, controlPort);

  @override
  String toString() =>
      'PreparationWorkerIdentity($name #$workerId, '
      'isolate: $isolateDebugName)';
}

/// Counters one worker isolate reports about its own execution.
final class WorkerExecutionStats {
  const WorkerExecutionStats({
    required this.handled,
    required this.droppedWhileQueued,
    required this.abortedMidJob,
    required this.yields,
    required this.workBytes,
  });

  static const WorkerExecutionStats empty = WorkerExecutionStats(
    handled: 0,
    droppedWhileQueued: 0,
    abortedMidJob: 0,
    yields: 0,
    workBytes: 0,
  );

  /// Jobs the worker ran to completion and answered.
  final int handled;

  /// Jobs cancelled before the worker started them.
  final int droppedWhileQueued;

  /// Jobs cancelled after the worker had started them.
  final int abortedMidJob;

  /// Times a running handler handed control back to the worker's event loop.
  final int yields;

  /// Bytes of input the handlers reported consuming.
  final int workBytes;

  @override
  String toString() =>
      'WorkerExecutionStats(handled: $handled, dropped: $droppedWhileQueued, '
      'abortedMidJob: $abortedMidJob, yields: $yields, '
      'workBytes: $workBytes)';
}

/// Main-isolate counters for one worker.
final class WorkerCallerStats {
  int submitted = 0;
  int completed = 0;
  int failed = 0;
  int cancelled = 0;

  /// Replies that arrived after the caller had already dropped the job.
  int lateRepliesDropped = 0;

  @override
  String toString() =>
      'WorkerCallerStats(submitted: $submitted, completed: $completed, '
      'failed: $failed, cancelled: $cancelled, late: $lateRepliesDropped)';
}

/// A long-lived isolate that executes preparation operations.
///
/// The isolate is spawned once and reused for every job. Jobs run one at a time
/// inside the isolate, so real parallelism comes from owning several workers
/// rather than from a concurrency counter inside one.
final class PreparationWorker {
  PreparationWorker._({
    required this.identity,
    required _WorkerChannel channel,
    required ReceivePort inbox,
    required ReceivePort errors,
    required ReceivePort exits,
    required SendPort control,
    required Isolate isolate,
  }) : _channel = channel,
       _inbox = inbox,
       _errors = errors,
       _exits = exits,
       _control = control,
       _isolate = isolate;

  /// Identity reported by the worker isolate itself during its handshake.
  final PreparationWorkerIdentity identity;

  final _WorkerChannel _channel;

  /// Ports this worker owns on the calling isolate. Every one of them is
  /// closed by [dispose]: a listening port keeps the calling isolate alive, so
  /// a disposed worker must leave the host with nothing outstanding.
  final ReceivePort _inbox;
  final ReceivePort _errors;
  final ReceivePort _exits;
  final SendPort _control;
  final Isolate _isolate;
  bool _closed = false;

  /// Spawns one worker isolate and waits for its identity handshake.
  ///
  /// [operations] are the handlers this worker accepts: tear-offs of top-level
  /// or static functions. The worker isolate shares the code of the spawning
  /// isolate, so no source is shipped at runtime.
  static Future<PreparationWorker> spawn({
    required String name,
    required Map<String, PreparationWorkerOperation> operations,
    int workerId = 0,
    String? debugName,
  }) async {
    if (operations.isEmpty) {
      throw ArgumentError.value(operations, 'operations', 'must not be empty');
    }
    final channel = _WorkerChannel();
    final inbox = ReceivePort();
    final errors = ReceivePort();
    final exits = ReceivePort();
    errors.listen(
      (Object? message) => channel.failAll(_isolateFailure(message ?? '')),
    );
    exits.listen(
      (Object? _) => channel.failAll(
        const PreparationWorkerClosedException('worker isolate exited'),
      ),
    );
    final Isolate isolate;
    try {
      isolate = await Isolate.spawn<List<Object?>>(
        preparationWorkerEntry,
        <Object?>[
          inbox.sendPort,
          name,
          workerId,
          Map<String, PreparationWorkerOperation>.of(operations),
        ],
        debugName: debugName ?? 'licoup-preparation-$name',
        errorsAreFatal: false,
        onError: errors.sendPort,
        onExit: exits.sendPort,
      );
    } catch (_) {
      inbox.close();
      errors.close();
      exits.close();
      rethrow;
    }
    inbox.listen(
      channel.route,
      onError: (Object error, StackTrace stack) =>
          channel.failAll(_isolateFailure(error)),
    );
    final _WorkerHello handshake;
    try {
      handshake = await channel.hello.future;
    } catch (_) {
      isolate.kill(priority: Isolate.immediate);
      inbox.close();
      errors.close();
      exits.close();
      rethrow;
    }
    return PreparationWorker._(
      identity: PreparationWorkerIdentity(
        name: handshake.name,
        workerId: handshake.workerId,
        isolateDebugName: handshake.isolateDebugName,
        controlPort: handshake.controlPort,
      ),
      channel: channel,
      inbox: inbox,
      errors: errors,
      exits: exits,
      control: handshake.receivePort,
      isolate: isolate,
    );
  }

  /// Jobs accepted by this worker that have not finished yet.
  int get pendingJobs => _channel.pending.length;

  /// Counters owned by the calling side.
  WorkerCallerStats get stats => _channel.callerStats;

  /// Counters reported by the worker isolate about its own execution.
  WorkerExecutionStats get workerStats => _channel.workerStats;

  bool get closed => _closed;

  /// Runs one operation inside the worker isolate.
  ///
  /// A cancelled, failed, or closed attempt completes with a
  /// [PreparationFailure] subtype: a typed outcome rather than an arbitrary
  /// exception crossing the isolate boundary.
  Future<Object?> execute({
    required String operation,
    Object? payload,
    PreparationCancellationToken? cancel,
    void Function()? onReleased,
  }) {
    if (_closed || _channel.failure != null) {
      return Future<Object?>.error(
        const PreparationWorkerClosedException('worker already closed'),
      );
    }
    final requested = cancel?.reason;
    if (requested != null) {
      _channel.callerStats.cancelled++;
      return Future<Object?>.error(
        PreparationCancelledException(requested, stage: 'queued'),
      );
    }
    final jobId = _channel.nextJobId();
    _channel.callerStats.submitted++;
    final job = _PendingJob(jobId);
    job.onReleased = onReleased;
    _channel.pending[jobId] = job;
    void onCancel(PreparationCancellationReason reason) {
      job.reason = reason;
      _cancelLocally(job, reason);
    }

    cancel?.addListener(onCancel);
    job.onSettled = () => cancel?.removeListener(onCancel);
    try {
      _control.send(<Object?>[_tagJob, jobId, operation, payload]);
    } catch (_) {
      _channel.pending.remove(jobId);
      job.release();
      _channel.callerStats.failed++;
      job.completeError(
        const PreparationWorkerException(
          code: 'preparation.payload_not_sendable',
          detail: 'operation payload cannot cross the isolate boundary',
        ),
      );
    }
    return job.completer.future;
  }

  /// Stops the worker isolate and fails every queued or running job.
  Future<void> dispose() async {
    if (_closed) return;
    _closed = true;
    const failure = PreparationWorkerClosedException('worker disposed');
    for (final job in _channel.pending.values.toList()) {
      _control.send(<Object?>[_tagCancel, job.jobId]);
      job.completeError(failure);
      job.release();
    }
    _channel.pending.clear();
    _control.send(const <Object?>[_tagShutdown]);
    try {
      await _channel.shutdownAck.future.timeout(const Duration(seconds: 10));
    } catch (_) {
      // A handler that never returns must not keep the isolate alive forever;
      // the kill below releases it unconditionally.
    }
    _isolate.kill(priority: Isolate.immediate);
    _inbox.close();
    _errors.close();
    _exits.close();
  }

  void _cancelLocally(_PendingJob job, PreparationCancellationReason reason) {
    if (!_channel.pending.containsKey(job.jobId)) return;
    _channel.callerStats.cancelled++;
    // Release the caller immediately and tell the worker too: the worker drops
    // the job at its next chunk boundary, and its reply is discarded later.
    _control.send(<Object?>[_tagCancel, job.jobId]);
    job.completeError(PreparationCancelledException(reason, stage: 'running'));
  }
}

PreparationWorkerException _isolateFailure(Object error) =>
    const PreparationWorkerException(
      code: 'preparation.worker_error',
      detail: 'worker isolate failed',
    );

/// Message tags of the worker protocol. Kept as small integers so a job payload
/// never has to be inspected to route a control message.
const int _tagHello = 0;
const int _tagJob = 1;
const int _tagCancel = 2;
const int _tagShutdown = 3;
const int _tagReply = 4;
const int _tagShutdownAck = 5;
const int _tagWorkerStats = 6;
const int _statusOk = 0;
const int _statusCancelled = 1;
const int _statusFailed = 2;

/// Entry point of the worker isolate.
///
/// Public because `Isolate.spawn` needs a top-level tear-off; it is not part of
/// the presentation API.
void preparationWorkerEntry(List<Object?> config) {
  final SendPort replies = config[0] as SendPort;
  final String name = config[1] as String;
  final int workerId = config[2] as int;
  final Map<String, PreparationWorkerOperation> operations =
      config[3] as Map<String, PreparationWorkerOperation>;
  final inbox = ReceivePort();
  final runner = _WorkerRunner(
    replies: replies,
    name: name,
    workerId: workerId,
    operations: operations,
  );
  replies.send(<Object?>[
    _tagHello,
    workerId,
    name,
    Isolate.current.debugName ?? '',
    Isolate.current.controlPort,
    inbox.sendPort,
  ]);
  inbox.listen(
    runner.handle,
    onError: (Object error, StackTrace stack) {
      replies.send(<Object?>[_tagWorkerStats, runner.encodeStats()]);
    },
  );
}

final class _WorkerHello {
  const _WorkerHello({
    required this.workerId,
    required this.name,
    required this.isolateDebugName,
    required this.controlPort,
    required this.receivePort,
  });

  final int workerId;
  final String name;
  final String isolateDebugName;
  final SendPort controlPort;
  final SendPort receivePort;
}

/// Caller-side routing state shared by the handshake and the worker object.
final class _WorkerChannel {
  final Map<int, _PendingJob> pending = <int, _PendingJob>{};
  final Completer<_WorkerHello> hello = Completer<_WorkerHello>();
  final Completer<void> shutdownAck = Completer<void>();
  final WorkerCallerStats callerStats = WorkerCallerStats();
  WorkerExecutionStats workerStats = WorkerExecutionStats.empty;
  int _nextJobId = 0;
  PreparationFailure? failure;

  int nextJobId() => ++_nextJobId;

  void route(Object? message) {
    if (message is! List<Object?> || message.isEmpty) return;
    switch (message[0] as int) {
      case _tagHello:
        if (!hello.isCompleted) {
          hello.complete(
            _WorkerHello(
              workerId: message[1] as int,
              name: message[2] as String,
              isolateDebugName: message[3] as String,
              controlPort: message[4] as SendPort,
              receivePort: message[5] as SendPort,
            ),
          );
        }
      case _tagReply:
        final job = pending.remove(message[1] as int);
        job?.release();
        if (job == null || job.completer.isCompleted) {
          // The caller already dropped this attempt (cancelled, superseded, or
          // disposed), so the late result must not be applied.
          callerStats.lateRepliesDropped++;
          return;
        }
        switch (message[2] as int) {
          case _statusOk:
            callerStats.completed++;
            job.complete(message[3]);
          case _statusCancelled:
            callerStats.cancelled++;
            job.completeError(
              PreparationCancelledException(
                job.reason ?? PreparationCancellationReason.superseded,
                stage: 'worker',
              ),
            );
          case _statusFailed:
            callerStats.failed++;
            job.completeError(
              PreparationWorkerException(
                code: message[4] as String,
                detail: message[5] as String,
              ),
            );
        }
      case _tagWorkerStats:
        workerStats = _decodeStats(message[1] as List<Object?>);
      case _tagShutdownAck:
        if (!shutdownAck.isCompleted) shutdownAck.complete();
    }
  }

  void failAll(PreparationFailure failure) {
    this.failure = failure;
    if (!hello.isCompleted) hello.completeError(failure);
    for (final job in pending.values.toList()) {
      job.completeError(failure);
      job.release();
    }
    pending.clear();
    if (!shutdownAck.isCompleted) shutdownAck.complete();
  }
}

/// Bookkeeping for one submitted job on the caller side.
final class _PendingJob {
  _PendingJob(this.jobId);

  final int jobId;
  final Completer<Object?> completer = Completer<Object?>();
  PreparationCancellationReason? reason;
  void Function()? onSettled;
  void Function()? onReleased;

  void release() {
    final callback = onReleased;
    onReleased = null;
    callback?.call();
  }

  void complete(Object? value) {
    if (!completer.isCompleted) {
      onSettled?.call();
      onSettled = null;
      completer.complete(value);
    }
  }

  void completeError(Object error) {
    if (!completer.isCompleted) {
      onSettled?.call();
      onSettled = null;
      completer.completeError(error, StackTrace.current);
    }
  }
}

WorkerExecutionStats _decodeStats(List<Object?> snapshot) {
  return WorkerExecutionStats(
    handled: snapshot[0] as int,
    droppedWhileQueued: snapshot[1] as int,
    abortedMidJob: snapshot[2] as int,
    yields: snapshot[3] as int,
    workBytes: snapshot[4] as int,
  );
}

/// Worker-isolate side: a one-job-at-a-time runner with a live control channel.
final class _WorkerRunner {
  _WorkerRunner({
    required this.replies,
    required this.name,
    required this.workerId,
    required this.operations,
  });

  final SendPort replies;
  final String name;
  final int workerId;
  final Map<String, PreparationWorkerOperation> operations;
  final ListQueue<_QueuedJob> _queue = ListQueue<_QueuedJob>();
  final Set<int> _cancelled = <int>{};
  int _handled = 0;
  int _droppedWhileQueued = 0;
  int _abortedMidJob = 0;
  int _yields = 0;
  int _workBytes = 0;
  bool _running = false;
  bool _shuttingDown = false;
  bool _shutdownAckSent = false;

  void handle(Object? message) {
    if (message is! List<Object?> || message.isEmpty) return;
    switch (message[0] as int) {
      case _tagJob:
        _queue.add(
          _QueuedJob(
            jobId: message[1] as int,
            operation: message[2] as String,
            payload: message[3],
          ),
        );
        unawaited(_pump());
      case _tagCancel:
        _cancelled.add(message[1] as int);
      case _tagShutdown:
        _shuttingDown = true;
        unawaited(_pump());
    }
  }

  List<Object?> encodeStats() => <Object?>[
    _handled,
    _droppedWhileQueued,
    _abortedMidJob,
    _yields,
    _workBytes,
  ];

  Future<void> _pump() async {
    if (_running) return;
    _running = true;
    while (_queue.isNotEmpty) {
      final job = _queue.removeFirst();
      final context = _RunnerJobContext(this, job.jobId);
      if (_cancelled.remove(job.jobId)) {
        _droppedWhileQueued++;
        _replyCancelled(job);
        continue;
      }
      final operation = operations[job.operation];
      if (operation == null) {
        _handled++;
        _reply(<Object?>[
          _tagReply,
          job.jobId,
          _statusFailed,
          null,
          'preparation.unknown_operation',
          'no handler for ${job.operation}',
        ]);
      } else {
        await _run(job, operation, context);
      }
    }
    _running = false;
    if (_shuttingDown && _queue.isEmpty && !_shutdownAckSent) {
      _shutdownAckSent = true;
      replies.send(const <Object?>[_tagShutdownAck]);
    }
  }

  Future<void> _run(
    _QueuedJob job,
    PreparationWorkerOperation operation,
    _RunnerJobContext context,
  ) async {
    try {
      final result = await operation(job.payload, context);
      if (_cancelled.remove(job.jobId)) {
        _abortedMidJob++;
        _replyCancelled(job);
        return;
      }
      _handled++;
      _reply(<Object?>[_tagReply, job.jobId, _statusOk, result, '', '']);
    } on PreparationFailure catch (failure) {
      if (_cancelled.remove(job.jobId)) {
        // The handler noticed the cancel: the attempt is aborted, not handled.
        _abortedMidJob++;
        _replyCancelled(job);
        return;
      }
      _handled++;
      _reply(<Object?>[
        _tagReply,
        job.jobId,
        _statusFailed,
        null,
        failure.code,
        failure.detail,
      ]);
    } catch (error) {
      _handled++;
      _reply(<Object?>[
        _tagReply,
        job.jobId,
        _statusFailed,
        null,
        'preparation.operation_failed',
        // The type only: an arbitrary error message can carry source text,
        // and the failure contract keeps details free of user content.
        '${error.runtimeType} in worker operation',
      ]);
    }
  }

  /// Sends counters first, then the reply, so a caller that observes the reply
  /// has already observed the worker's own view of what it did.
  void _reply(List<Object?> message) {
    replies.send(<Object?>[_tagWorkerStats, encodeStats()]);
    replies.send(message);
  }

  void _replyCancelled(_QueuedJob job) {
    _reply(<Object?>[_tagReply, job.jobId, _statusCancelled, null, '', '']);
  }

  bool isCancelled(int jobId) => _cancelled.contains(jobId);

  void registerYield() => _yields++;

  void registerWork(int bytes) => _workBytes += bytes;
}

final class _QueuedJob {
  const _QueuedJob({
    required this.jobId,
    required this.operation,
    required this.payload,
  });

  final int jobId;
  final String operation;
  final Object? payload;
}

final class _RunnerJobContext implements WorkerJobContext {
  _RunnerJobContext(this._runner, this._jobId);

  final _WorkerRunner _runner;
  final int _jobId;
  int _yieldCount = 0;

  @override
  bool get isCancelled => _runner.isCancelled(_jobId);

  @override
  int get yieldCount => _yieldCount;

  @override
  Future<void> yieldToControl() async {
    _yieldCount++;
    _runner.registerYield();
    // A timer event, not a microtask: microtasks run before the worker's
    // message queue, so only a real event-loop turn can receive a cancel.
    await Future<void>.delayed(Duration.zero);
  }

  @override
  void recordWorkBytes(int bytes) => _runner.registerWork(bytes);
}
