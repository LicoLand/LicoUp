import 'dart:async';
import 'dart:io';

import 'package:licoup/src/application/controller/client_lifecycle_coordinator.dart';
import 'package:licoup/src/contracts/client_lifecycle_diagnostics.dart';

/// Turns a caught bootstrap failure into one bounded local diagnostic record.
///
/// The write is fire-and-forget: a diagnostics failure must never mask or
/// replace the lifecycle failure being recorded.
final class ClientLifecycleDiagnosticJournal {
  ClientLifecycleDiagnosticJournal({
    required ClientLifecycleDiagnosticSink sink,
    DateTime Function()? now,
    String Function()? homeDirectory,
  }) : _sink = sink,
       _now = now ?? DateTime.now,
       _homeDirectory =
           homeDirectory ?? (() => Platform.environment['HOME'] ?? '');

  static const int _stackFrameLimit = 6;

  final ClientLifecycleDiagnosticSink _sink;
  final DateTime Function() _now;
  final String Function() _homeDirectory;

  void recordFailure(
    ClientLifecycleReport report,
    Object error,
    StackTrace stackTrace,
  ) {
    final home = _homeDirectory();
    final record = ClientLifecycleDiagnosticRecord(
      createdAt: _now().toUtc(),
      code: report.code,
      stepId: report.stepId,
      errorType: error.runtimeType.toString(),
      detail: sanitizeClientLifecycleDiagnosticText(
        error.toString(),
        homeDirectory: home,
      ),
      stack: sanitizeClientLifecycleDiagnosticText(
        stackTrace.toString().split('\n').take(_stackFrameLimit).join(' | '),
        homeDirectory: home,
        maxLength: 640,
      ),
    );
    unawaited(_sink.record(record).catchError((_) {}));
  }
}
