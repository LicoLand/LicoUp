import 'dart:async';

import 'package:presentation_runtime/src/scheduling/preparation_cancellation.dart';
import 'package:presentation_runtime/src/scheduling/preparation_executor.dart';
import 'package:presentation_runtime/src/scheduling/preparation_worker.dart';
import 'package:presentation_runtime/src/scheduling/preparation_worker_pool.dart';
import 'package:test/test.dart';

/// A chunked job: it burns one chunk of CPU, then yields to the worker's event
/// loop, which is the only point where a cancel message can reach the handler.
///
/// The chunk is long enough that the caller can observe the pool while the
/// worker has not acknowledged the cancellation yet.
Future<Object?> _chunked(Object? payload, WorkerJobContext context) async {
  final config = payload! as Map<Object?, Object?>;
  final chunks = config['chunks']! as int;
  final microsPerChunk = config['microsPerChunk']! as int;
  for (var chunk = 0; chunk < chunks; chunk++) {
    if (context.isCancelled) {
      throw const PreparationCancelledException(
        PreparationCancellationReason.superseded,
        stage: 'chunk',
      );
    }
    final watch = Stopwatch()..start();
    while (watch.elapsedMicroseconds < microsPerChunk) {}
    await context.yieldToControl();
  }
  return chunks;
}

Object? _echo(Object? payload, WorkerJobContext context) => payload;

final Map<String, PreparationWorkerOperation> _operations =
    <String, PreparationWorkerOperation>{'chunked': _chunked, 'echo': _echo};

void main() {
  test(
    'a cancelled running unit keeps its slot until the worker acknowledges it',
    () async {
      final pool = await PreparationWorkerPool.spawn(
        name: 'capacity',
        operations: _operations,
        workers: 1,
      );

      final token = PreparationCancellationToken();
      final running = pool.execute(
        operation: 'chunked',
        payload: <Object?, Object?>{'chunks': 40, 'microsPerChunk': 150000},
        cancel: token,
      );
      final queued = <Future<Object?>>[
        for (var index = 0; index < 63; index++)
          pool.execute(operation: 'echo', payload: index),
      ];
      expect(
        pool.pendingJobs,
        64,
        reason: 'the running unit and the queue fill the cap exactly',
      );

      final cancelled = expectLater(
        running,
        throwsA(
          isA<PreparationCancelledException>().having(
            (error) => error.stage,
            'stage',
            'running',
          ),
        ),
      );
      token.cancel(PreparationCancellationReason.superseded);
      await cancelled;
      expect(
        pool.pendingJobs,
        64,
        reason:
            'the caller stopped waiting, but the worker has not acknowledged '
            'the cancellation, so the unit still owns its slot',
      );
      await expectLater(
        pool.execute(operation: 'echo', payload: 'beyond-cap'),
        throwsA(isA<PreparationBackpressureException>()),
      );

      await pool.idle;
      expect(pool.pendingJobs, 0);
      expect(
        await Future.wait<Object?>(queued),
        <Object?>[for (var index = 0; index < 63; index++) index],
        reason: 'every queued unit completed with its own result',
      );
      expect(
        pool.workerStats.abortedMidJob,
        greaterThan(0),
        reason: 'the worker acknowledged the cancellation between chunks',
      );
      expect(
        pool.workerStats.handled,
        63,
        reason: 'the cancelled unit never completed; every queued unit did',
      );

      expect(
        await pool.execute(operation: 'echo', payload: 'replacement'),
        'replacement',
        reason: 'the acknowledged slot is reusable at the same cap',
      );
      await pool.dispose();
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('the pool measures pending bytes and refuses to exceed them', () async {
    final pool = await PreparationWorkerPool.spawn(
      name: 'capacity-bytes',
      operations: _operations,
      workers: 1,
    );
    final running = pool.execute(operation: 'echo', payload: 0);
    await running;

    // The pool admits work up to its byte ceiling, and refuses the unit that
    // would cross it instead of growing past the bound.
    final admitted = <Future<Object?>>[
      for (var index = 0; index < 4; index++)
        pool.execute(
          operation: 'echo',
          payload: index,
          estimatedBytes: 1024 * 1024,
        ),
    ];
    await expectLater(
      pool.execute(
        operation: 'echo',
        payload: 'beyond-bytes',
        estimatedBytes: 1024 * 1024,
      ),
      throwsA(
        isA<PreparationBackpressureException>().having(
          (error) => error.requestedBytes,
          'requestedBytes',
          1024 * 1024,
        ),
      ),
    );
    expect(await Future.wait<Object?>(admitted), <Object?>[0, 1, 2, 3]);
    await pool.dispose();
  });
}
