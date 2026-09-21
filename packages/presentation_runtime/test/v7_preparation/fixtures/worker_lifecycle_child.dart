// Fixture for `worker_lifecycle_test.dart`: a real program that spawns real
// worker isolates, runs jobs through a pool, releases it, and then must be able
// to leave its own isolate.
//
// It is deliberately not a test file: the parent test starts it with
// `Isolate.spawnUri` and observes whether the isolate terminates on its own.
import 'dart:io';

import 'package:presentation_runtime/presentation_runtime.dart';

Object? _echo(Object? payload, WorkerJobContext context) => payload;

Object? _boom(Object? payload, WorkerJobContext context) {
  throw const PreparationWorkerException(
    code: 'preparation.probe_failed',
    detail: 'synthetic probe workload failure',
  );
}

final Map<String, PreparationWorkerOperation> _operations =
    <String, PreparationWorkerOperation>{'echo': _echo, 'boom': _boom};

Future<void> main(List<String> args) async {
  final report = File(args.first);

  // Phase A: a serving pool runs real jobs and is disposed.
  final pool = await PreparationWorkerPool.spawn(
    name: 'lifecycle',
    operations: _operations,
    workers: 2,
  );
  final results = await Future.wait<Object?>(<Future<Object?>>[
    for (var job = 0; job < 3; job++)
      pool.execute(operation: 'echo', payload: <String, Object?>{'job': job}),
  ]);
  final identities = pool.identities;
  final stats = pool.workerStats;
  await pool.dispose();

  // Phase B: a measured pool whose probe workload fails must release the probe
  // pool it already spawned instead of leaving it running.
  String probeOutcome;
  try {
    await PreparationWorkerPool.spawnMeasured(
      name: 'lifecycle-probe',
      operations: _operations,
      workloadOperation: 'boom',
      workloadPayload: null,
      probeJobs: 2,
      maxCandidates: 2,
    );
    probeOutcome = 'probe=unexpected-success';
  } on PreparationFailure catch (failure) {
    probeOutcome = 'probe=${failure.code}';
  }

  report.writeAsStringSync(
    <String>[
      'results=${results.length}',
      'workers=${identities.length}',
      'workerIds=${identities.map((identity) => identity.workerId).join(",")}',
      'distinctPorts=${identities.map((identity) => identity.controlPort).toSet().length}',
      'ranInCaller=${identities.any((identity) => identity.runsInCallerIsolate)}',
      'handled=${stats.handled}',
      'disposed=${pool.disposed}',
      probeOutcome,
    ].join('\n'),
  );
}
