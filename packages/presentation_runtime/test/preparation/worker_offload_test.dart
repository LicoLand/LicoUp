import 'dart:async';
import 'dart:isolate';

import 'package:presentation_runtime/src/scheduling/preparation_cancellation.dart';
import 'package:presentation_runtime/src/scheduling/preparation_executor.dart';
import 'package:presentation_runtime/src/scheduling/preparation_worker.dart';
import 'package:presentation_runtime/src/scheduling/preparation_worker_pool.dart';
import 'package:test/test.dart';

/// Reports what the executing isolate observed about itself.
Object? _identityPayload(Object? payload, WorkerJobContext context) {
  return <Object?>[
    Isolate.current.controlPort,
    Isolate.current.debugName ?? '',
    payload,
    Isolate.current.controlPort == payload,
  ];
}

/// Burns CPU synchronously for [payload] microseconds inside the executor.
Object? _busyPayload(Object? payload, WorkerJobContext context) {
  final micros = payload! as int;
  final watch = Stopwatch()..start();
  var loops = 0;
  while (watch.elapsedMicroseconds < micros) {
    loops++;
  }
  context.recordWorkBytes(loops);
  return loops;
}

/// A chunked job: yields every chunk so a cancel can be received mid-job.
Future<Object?> _chunkedPayload(
  Object? payload,
  WorkerJobContext context,
) async {
  final config = payload! as Map<Object?, Object?>;
  final chunks = config['chunks']! as int;
  final microsPerChunk = config['microsPerChunk']! as int;
  var loops = 0;
  for (var chunk = 0; chunk < chunks; chunk++) {
    if (context.isCancelled) {
      throw const PreparationCancelledException(
        PreparationCancellationReason.superseded,
        stage: 'chunk',
      );
    }
    final watch = Stopwatch()..start();
    while (watch.elapsedMicroseconds < microsPerChunk) {
      loops++;
    }
    context.recordWorkBytes(microsPerChunk);
    await context.yieldToControl();
  }
  return loops;
}

Object? _throwsPayload(Object? payload, WorkerJobContext context) {
  throw StateError('handler exploded');
}

Object? _failurePayload(Object? payload, WorkerJobContext context) {
  throw const PreparationWorkerException(
    code: 'markdown.region_not_single_block',
    detail: 'synthetic',
  );
}

final Map<String, PreparationWorkerOperation> _operations =
    <String, PreparationWorkerOperation>{
      'identity': _identityPayload,
      'busy': _busyPayload,
      'chunked': _chunkedPayload,
      'throws': _throwsPayload,
      'failure': _failurePayload,
    };

Future<PreparationWorker> _spawnWorker() => PreparationWorker.spawn(
  name: 'test',
  operations: _operations,
  debugName: 'licoup-preparation-test',
);

/// Counts how often [start] leaves the calling isolate able to run a timer.
///
/// The probe is the falsifiable part of offload: if the work runs on the
/// calling isolate, the timer cannot tick before the work finishes.
Future<int> _ticksWhileRunning(Future<void> Function() start) async {
  var done = false;
  final job = start().then<void>((_) => done = true);
  var ticks = 0;
  final timer = Timer.periodic(const Duration(milliseconds: 1), (_) {
    if (!done) ticks++;
  });
  await job;
  timer.cancel();
  await Future<void>.delayed(Duration.zero);
  return ticks;
}

void main() {
  test('a worker is a real isolate, reported by the worker itself', () async {
    final worker = await _spawnWorker();
    final mainPort = Isolate.current.controlPort;

    final identity = worker.identity;
    expect(identity.isolateDebugName, 'licoup-preparation-test');
    expect(identity.runsInCallerIsolate, isFalse);
    expect(identity.controlPort == mainPort, isFalse);

    // The comparison above is meaningful: a port sent out and returned for the
    // same port still compares equal, so the worker is a different isolate.
    final echoed = await worker.execute(
      operation: 'identity',
      payload: mainPort,
    );
    final reply = echoed! as List<Object?>;
    expect(reply[2], mainPort);
    expect(reply[3], isFalse);
    expect(reply[1], isNot(Isolate.current.debugName));

    await worker.dispose();
  });

  test('the calling isolate keeps running while the worker is busy', () async {
    final worker = await _spawnWorker();
    var workerTicks = 0;
    workerTicks = await _ticksWhileRunning(() async {
      await worker.execute(operation: 'busy', payload: 120000);
    });

    // Negative control: the same probe over in-isolate work cannot tick, so a
    // microtask or Future.sync based "offload" fails this check.
    final localTicks = await _ticksWhileRunning(() async {
      await Future<void>.sync(() {
        Object? loops = _busyPayload(120000, _ProbeContext());
        return loops;
      });
    });

    expect(workerTicks, greaterThan(0));
    expect(localTicks, 0);
    expect(worker.workerStats.handled, 1);
    await worker.dispose();
  });

  test('a running job is cancelled between chunks', () async {
    final worker = await _spawnWorker();
    final token = PreparationCancellationToken();
    final job = worker.execute(
      operation: 'chunked',
      payload: <Object?, Object?>{'chunks': 60, 'microsPerChunk': 3000},
      cancel: token,
    );
    // Let the worker start and yield at least once before cancelling.
    await Future<void>.delayed(const Duration(milliseconds: 30));
    token.cancel(PreparationCancellationReason.superseded);

    await expectLater(
      job,
      throwsA(
        isA<PreparationCancelledException>().having(
          (error) => error.reason,
          'reason',
          PreparationCancellationReason.superseded,
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(worker.stats.cancelled, 1);
    expect(worker.stats.lateRepliesDropped, greaterThan(0));
    expect(worker.workerStats.yields, greaterThan(0));
    expect(worker.workerStats.abortedMidJob, greaterThan(0));
    await worker.dispose();
  });

  test('a job cancelled before dispatch never reaches the worker', () async {
    final worker = await _spawnWorker();
    final token = PreparationCancellationToken()
      ..cancel(PreparationCancellationReason.revoked);

    await expectLater(
      worker.execute(operation: 'busy', payload: 1000, cancel: token),
      throwsA(
        isA<PreparationCancelledException>().having(
          (error) => error.stage,
          'stage',
          'queued',
        ),
      ),
    );
    expect(worker.stats.submitted, 0);
    expect(worker.workerStats.handled, 0);
    await worker.dispose();
  });

  test('worker failures come back as typed errors', () async {
    final worker = await _spawnWorker();

    await expectLater(
      worker.execute(operation: 'missing', payload: null),
      throwsA(
        isA<PreparationWorkerException>().having(
          (error) => error.code,
          'code',
          'preparation.unknown_operation',
        ),
      ),
    );
    await expectLater(
      worker.execute(operation: 'throws', payload: null),
      throwsA(
        isA<PreparationWorkerException>().having(
          (error) => error.code,
          'code',
          'preparation.operation_failed',
        ),
      ),
    );
    await expectLater(
      worker.execute(operation: 'failure', payload: null),
      throwsA(
        isA<PreparationWorkerException>().having(
          (error) => error.code,
          'code',
          'markdown.region_not_single_block',
        ),
      ),
    );
    expect(worker.stats.failed, 3);
    await worker.dispose();
  });

  test('disposal fails in-flight work with a typed error', () async {
    final worker = await _spawnWorker();
    final job = worker.execute(operation: 'busy', payload: 100000);
    final expectation = expectLater(
      job,
      throwsA(isA<PreparationWorkerClosedException>()),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await worker.dispose();
    await expectation;
    expect(worker.closed, isTrue);
  });

  test('pool size comes from a measured probe on this machine', () async {
    final pool = await PreparationWorkerPool.spawnMeasured(
      name: 'measured',
      operations: _operations,
      workloadOperation: 'busy',
      workloadPayload: 6000,
      probeJobs: 3,
      maxCandidates: 3,
    );

    final measurement = pool.measurement!;
    expect(measurement.workers, greaterThanOrEqualTo(1));
    expect(measurement.candidates.length, greaterThanOrEqualTo(1));
    expect(
      measurement.measuredElapsed.keys.toSet(),
      measurement.candidates.toSet(),
    );
    expect(pool.workers, measurement.workers);
    expect(pool.identities, hasLength(measurement.workers));
    expect(
      pool.identities.every((identity) => !identity.runsInCallerIsolate),
      isTrue,
    );
    expect(
      pool.identities.map((identity) => identity.controlPort).toSet(),
      hasLength(measurement.workers),
    );
    expect(
      pool.identities.map((identity) => identity.workerId).toSet(),
      hasLength(measurement.workers),
    );

    final results = await Future.wait<Object?>(<Future<Object?>>[
      for (var index = 0; index < measurement.workers * 2; index++)
        pool.execute(operation: 'busy', payload: 2000),
    ]);
    expect(results, hasLength(measurement.workers * 2));
    expect(
      pool.workerStats.handled,
      measurement.workers * 2,
      reason: 'the same long-lived isolates served every job',
    );
    expect(pool.pendingJobs, 0);
    await pool.dispose();
  });

  test(
    'a cancelled queue entry frees its slot and never reaches the worker',
    () async {
      final pool = await PreparationWorkerPool.spawn(
        name: 'queue',
        operations: _operations,
        workers: 1,
      );
      // Occupy the only worker so the next job has to wait in the pool queue.
      final running = pool.execute(operation: 'busy', payload: 150000);
      final token = PreparationCancellationToken();
      final queued = pool.execute(
        operation: 'busy',
        payload: 10000,
        cancel: token,
      );
      final queuedExpectation = expectLater(
        queued,
        throwsA(
          isA<PreparationCancelledException>().having(
            (error) => error.stage,
            'stage',
            'queued',
          ),
        ),
      );
      final third = pool.execute(operation: 'busy', payload: 1000);
      token.cancel(PreparationCancellationReason.superseded);

      await queuedExpectation;
      await running;
      await third;
      await pool.idle;
      expect(pool.pendingJobs, 0);
      expect(
        pool.workerStats.handled,
        2,
        reason: 'the cancelled queue entry was never dispatched',
      );
      await pool.dispose();
    },
  );

  test('the pool bounds accepted work instead of growing forever', () async {
    final pool = await PreparationWorkerPool.spawn(
      name: 'bounded',
      operations: _operations,
      workers: 1,
    );
    final running = pool.execute(operation: 'busy', payload: 200000);
    final queued = <Future<Object?>>[
      for (var index = 0; index < 63; index++)
        pool.execute(operation: 'echo', payload: index),
    ];
    expect(pool.pendingJobs, 64);

    await expectLater(
      pool.execute(operation: 'echo', payload: 'overflow'),
      throwsA(isA<PreparationBackpressureException>()),
    );

    // Releasing the pool settles every accepted job with a typed failure.
    final settled = Future.wait<void>(<Future<void>>[
      for (final future in <Future<Object?>>[running, ...queued])
        future.then<void>((_) {}, onError: (Object _) {}),
    ]);
    await pool.dispose();
    await settled;
    expect(pool.disposed, isTrue);
  });
}

/// Context used only by the in-isolate negative control.
final class _ProbeContext implements WorkerJobContext {
  @override
  bool get isCancelled => false;

  @override
  int get yieldCount => 0;

  @override
  Future<void> yieldToControl() => Future<void>.value();

  @override
  void recordWorkBytes(int bytes) {}
}
