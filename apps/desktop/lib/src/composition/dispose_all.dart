import 'dart:async';

/// Runs every registered cleanup in order and rethrows the first failure only
/// after the remaining independently-owned resources have been released.
Future<void> disposeAll(Iterable<FutureOr<void> Function()> cleanups) async {
  Object? firstError;
  StackTrace? firstStackTrace;
  for (final cleanup in cleanups) {
    try {
      await cleanup();
    } catch (error, stackTrace) {
      firstError ??= error;
      firstStackTrace ??= stackTrace;
    }
  }
  if (firstError != null) {
    Error.throwWithStackTrace(firstError, firstStackTrace!);
  }
}
