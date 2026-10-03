import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// A real worker owns ports on the isolate that spawned it, and a listening
/// port keeps that isolate alive. Disposing a pool therefore has to release
/// every port it opened, or a long-lived host (the app, a test runner, a CLI)
/// keeps a ghost isolate alive for each worker it ever spawned.
///
/// The fixture runs as its own process: an isolate that leaks a listening port
/// keeps the event loop alive, so the process simply never terminates and the
/// exit is the observation point. `dart test` hides this class of defect
/// because the runner tears its own isolates down after the suite, and the
/// engine shell behind `flutter test` cannot start an isolate from a source URI
/// at all, so the fixture is started with a real Dart VM. The VM is the SDK that
/// owns the running engine, or `dart` on `PATH`.
void main() {
  test(
    'a disposed worker pool leaves its host process free to exit',
    () async {
      final packageRoot = _packageRoot();
      final fixture = File(
        '${packageRoot.path}/test/preparation/fixtures/'
        'worker_lifecycle_child.dart',
      );
      final packageConfig = File(
        '${packageRoot.path}/.dart_tool/package_config.json',
      );
      expect(
        fixture.existsSync(),
        isTrue,
        reason: 'the lifecycle fixture ships with this package',
      );
      expect(
        packageConfig.existsSync(),
        isTrue,
        reason: 'the fixture resolves packages through this package config',
      );

      final tempDir = Directory.systemTemp.createTempSync(
        'prepared-workers-lifecycle',
      );
      final report = File('${tempDir.path}/report.txt');
      final process = await Process.start(_dartExecutable(), <String>[
        '--packages=${packageConfig.path}',
        fixture.path,
        report.path,
      ], workingDirectory: packageRoot.path);
      final transcript = StringBuffer();
      final drained = <Future<void>>[
        process.stdout
            .transform(const Utf8Decoder(allowMalformed: true))
            .listen(transcript.write)
            .asFuture<void>(),
        process.stderr
            .transform(const Utf8Decoder(allowMalformed: true))
            .listen(transcript.write)
            .asFuture<void>(),
      ];
      final exitCode = await process.exitCode.timeout(
        const Duration(seconds: 90),
        onTimeout: () {
          process.kill(ProcessSignal.sigkill);
          return _neverExited;
        },
      );
      await Future.wait<void>(drained);

      expect(
        exitCode,
        isNot(_neverExited),
        reason:
            'the fixture process never terminated: a disposed worker still '
            'holds a listening port on the isolate that spawned it',
      );
      expect(
        exitCode,
        0,
        reason: 'the fixture itself must succeed; transcript:\n$transcript',
      );
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

/// Exit code reported when the fixture process had to be killed.
const int _neverExited = -1;

/// The Dart VM that runs the lifecycle fixture.
///
/// The package suite is verified with `flutter test`, where the running process
/// is the engine's `flutter_tester` shell and cannot start an isolate from
/// source, so the VM is resolved to the SDK that owns the running engine, or to
/// `dart` on `PATH`.
String _dartExecutable() {
  final resolved = Platform.resolvedExecutable;
  if (_binaryName(resolved) == _dartBinary) return resolved;
  for (final candidate in _dartCandidates(resolved)) {
    if (File(candidate).existsSync()) return candidate;
  }
  throw StateError(
    'no Dart SDK executable found for the worker lifecycle fixture; '
    'resolved executable: $resolved',
  );
}

List<String> _dartCandidates(String resolved) {
  final candidates = <String>[];
  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  if (flutterRoot != null && flutterRoot.isNotEmpty) {
    candidates.add('$flutterRoot/bin/cache/dart-sdk/bin/$_dartBinary');
  }
  var directory = File(resolved).parent;
  while (true) {
    candidates
      ..add('${directory.path}/bin/cache/dart-sdk/bin/$_dartBinary')
      ..add('${directory.path}/cache/dart-sdk/bin/$_dartBinary');
    final parent = directory.parent;
    if (parent.path == directory.path) break;
    directory = parent;
  }
  for (final entry in (Platform.environment['PATH'] ?? '').split(':')) {
    if (entry.isNotEmpty) candidates.add('$entry/$_dartBinary');
  }
  return candidates;
}

String _binaryName(String path) => path.split(Platform.pathSeparator).last;

final String _dartBinary = Platform.isWindows ? 'dart.exe' : 'dart';

/// The package root, whether the suite runs from this package or the checkout.
Directory _packageRoot() {
  var directory = Directory.current.absolute;
  while (true) {
    final pubspec = File('${directory.path}/pubspec.yaml');
    if (pubspec.existsSync() &&
        pubspec.readAsStringSync().contains('name: presentation_runtime')) {
      return directory;
    }
    final parent = directory.parent;
    if (parent.path == directory.path) break;
    directory = parent;
  }
  throw StateError(
    'presentation_runtime package root not found from '
    '${Directory.current.path}',
  );
}
