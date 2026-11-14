import 'dart:async';

/// Runs desktop tests with Flutter's strict [LocalFileComparator] so visual
/// golden suites compare exact platform-specific baselines rather than masking
/// cross-OS rendering drift behind pixel tolerances.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  await testMain();
}
