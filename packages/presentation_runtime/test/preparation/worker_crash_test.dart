import 'dart:async';
import 'dart:isolate';

import 'package:presentation_runtime/src/scheduling/preparation_cancellation.dart';
import 'package:presentation_runtime/src/scheduling/preparation_worker.dart';
import 'package:presentation_runtime/src/scheduling/preparation_worker_pool.dart';
import 'package:test/test.dart';

/// Kills the worker isolate that runs this handler after [payload] milliseconds,
/// once the caller has had time to admit more work behind it.
///
/// A handler cannot normally stop its isolate, which is exactly why this is the
/// honest crash: the pool observes the isolate's exit port, not a thrown error.
Future<Object?> _crash(Object? payload, WorkerJobContext context) async {
  await Future<void>.delayed(Duration(milliseconds: payload! as int));
  Isolate.current.kill(priority: Isolate.immediate);
  return null;
}

/// Burns CPU synchronously for [payload] microseconds inside the worker.
Object? _busy(Object? payload, WorkerJobContext context) {
  final micros = payload! as int;
  final watch = Stopwatch()..start();
  while (watch.elapsedMicroseconds < micros) {}
  return micros;
}

Object? _echo(Object? payload, WorkerJobContext context) => payload;

final Map<String, PreparationWorkerOperation> _operations =
    <String, PreparationWorkerOperation>{
      'crash': _crash,
      'busy': _busy,
      'echo': _echo,
    };

void main() {
  test(
    'work admitted beside a crashed worker moves to a live sibling',
    () async {
      final pool = await PreparationWorkerPool.spawn(
        name: 'crash-sibling',
        operations: _operations,
        workers: 2,
      );
      // The pool dispatches the least loaded worker first, so the crash lands
      // on worker 0 while worker 1 is still held by a long job.
      final crash = pool.execute(operation: 'crash', payload: 60);
      final crashExpectation = expectLater(
        crash,
        throwsA(isA<PreparationWorkerClosedException>()),
      );
      final held = pool.execute(operation: 'busy', payload: 250000);
      final waiting = pool.execute(operation: 'echo', payload: 'waiting');

      await crashExpectation;
      expect(
        pool.liveWorkers,
        1,
        reason: 'the exited worker is out of rotation',
      );
      expect(
        pool.pendingJobs,
        2,
        reason: 'the held job and the admitted job are still owned by the pool',
      );

      expect(await held, 250000);
      expect(
        await waiting,
        'waiting',
        reason:
            'admitted work that never started moves to the surviving worker',
      );
      expect(pool.pendingJobs, 0);
      expect(
        pool.workerStats.handled,
        2,
        reason: 'both admitted jobs ran exactly once, on the survivor',
      );
      await pool.dispose();
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'queued work fails typed when every worker isolate has exited',
    () async {
      final pool = await PreparationWorkerPool.spawn(
        name: 'crash-last',
        operations: _operations,
        workers: 1,
      );
      final crash = pool.execute(operation: 'crash', payload: 60);
      final admitted = <Future<Object?>>[
        for (var index = 0; index < 3; index++)
          pool.execute(operation: 'echo', payload: index),
      ];
      final failures = <Object?>[];
      final settled = Future.wait<void>(<Future<void>>[
        for (final future in admitted)
          future.then<void>(
            (Object? _) {},
            onError: (Object error) => failures.add(error),
          ),
      ]);

      await expectLater(
        crash,
        throwsA(isA<PreparationWorkerClosedException>()),
      );
      await settled;
      expect(pool.liveWorkers, 0);
      expect(
        failures,
        hasLength(3),
        reason: 'every admitted job settles exactly once instead of hanging',
      );
      expect(
        failures.every((error) => error is PreparationWorkerClosedException),
        isTrue,
        reason: 'a job with nowhere to run fails typed: $failures',
      );
      expect(
        pool.pendingJobs,
        0,
        reason: 'no admitted work is stranded behind an exited worker',
      );
      expect(
        pool.workerStats.handled,
        0,
        reason: 'nothing ran twice while the worker was exiting',
      );
      await pool.dispose();
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
