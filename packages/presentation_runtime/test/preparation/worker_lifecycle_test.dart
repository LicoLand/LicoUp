import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:test/test.dart';

import 'fixtures/worker_lifecycle_child.dart';

/// A real worker owns ports on the isolate that spawned it, and a listening
/// port keeps that isolate alive. Disposing a pool therefore has to release
/// every port it opened, or a long-lived host (the app, a test runner, a CLI)
/// keeps a ghost isolate alive for each worker it ever spawned.
///
/// The check is a separate isolate rather than this one: an isolate that leaks
/// a listening port simply never terminates, and `onExit` is the observation
/// point. `dart test` hides this class of defect because the runner tears its
/// own isolates down. The child is spawned same-code: the Flutter tester only
/// resolves packages asynchronously, so a nested `Isolate.spawnUri` cannot
/// resolve its package config there.
void main() {
  test(
    'a disposed worker pool leaves its host isolate free to exit',
    () async {
      final tempDir = Directory.systemTemp.createTempSync(
        'preparation-lifecycle',
      );
      final report = File('${tempDir.path}/report.txt');
      final exits = ReceivePort();
      final errors = ReceivePort();
      final exitSignal = Completer<Object?>();
      final failures = <Object?>[];
      exits.listen((Object? message) => exitSignal.complete(message));
      errors.listen(failures.add);

      final isolate = await Isolate.spawn<Object?>(
        workerLifecycleChildEntry,
        report.path,
        onExit: exits.sendPort,
        onError: errors.sendPort,
        errorsAreFatal: false,
      );

      final exited = await exitSignal.future.timeout(
        const Duration(seconds: 90),
        onTimeout: () => _neverExited,
      );
      if (exited == _neverExited) {
        isolate.kill(priority: Isolate.immediate);
      }
      exits.close();
      errors.close();

      expect(
        exited,
        isNot(_neverExited),
        reason:
            'the child isolate never terminated: a disposed worker still '
            'holds a listening port on the isolate that spawned it',
      );
      expect(failures, isEmpty, reason: 'the fixture itself must not fail');
      final lines = report.readAsLinesSync();
      expect(lines, contains('results=3'));
      expect(lines, contains('workers=2'));
      expect(
        lines,
        contains('workerIds=0,1'),
        reason: 'two workers means two real, distinct isolates',
      );
      expect(lines, contains('distinctPorts=2'));
      expect(lines, contains('ranInCaller=false'));
      expect(lines, contains('handled=3'));
      expect(lines, contains('disposed=true'));
      expect(
        lines,
        contains('probe=preparation.probe_failed'),
        reason: 'the failing probe workload must reach the caller as a failure',
      );
      tempDir.deleteSync(recursive: true);
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}

const String _neverExited = 'never-exited';
