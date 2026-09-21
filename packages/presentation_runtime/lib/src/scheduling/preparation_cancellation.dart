import 'dart:async';

/// Why an asynchronous preparation stopped being wanted.
///
/// The reason is carried into the failure so a caller can distinguish a
/// superseded attempt (a newer generation exists) from a revoked or disposed
/// one, instead of treating every aborted attempt as a transport error.
enum PreparationCancellationReason { superseded, revoked, disposed, caller }

/// A preparation attempt that must not install a result.
///
/// Every subtype is a plain immutable value with a stable machine [code], so a
/// worker-side failure can cross an isolate boundary without transferring an
/// arbitrary exception object.
sealed class PreparationFailure implements Exception {
  const PreparationFailure();

  /// Stable machine-readable code.
  String get code;

  /// Human-readable detail. Never contains source text or user content.
  String get detail;

  @override
  String toString() => '$runtimeType($code): $detail';
}

/// A cancelled or superseded preparation.
final class PreparationCancelledException extends PreparationFailure {
  const PreparationCancelledException(this.reason, {this.stage = 'running'});

  final PreparationCancellationReason reason;

  /// Where the attempt stopped: `queued`, `running`, or `install`.
  final String stage;

  @override
  String get code => 'preparation.cancelled';

  @override
  String get detail => '${reason.name} while $stage';
}

/// A preparation operation failed inside the worker.
final class PreparationWorkerException extends PreparationFailure {
  const PreparationWorkerException({required this.code, required this.detail});

  @override
  final String code;

  @override
  final String detail;
}

/// The worker (or pool) was shut down before the attempt finished.
final class PreparationWorkerClosedException extends PreparationFailure {
  const PreparationWorkerClosedException([this.detail = 'worker closed']);

  @override
  String get code => 'preparation.worker_closed';

  @override
  final String detail;
}

/// Cooperative cancellation handle shared by a caller, a worker, and an
/// installer gate.
///
/// The token never cancels work by itself: it publishes the intent, the worker
/// observes it at its next chunk boundary, and the installer refuses to publish
/// a member whose token fired. A late result is therefore dropped twice over.
final class PreparationCancellationToken {
  PreparationCancellationToken();

  final List<void Function(PreparationCancellationReason reason)> _listeners =
      <void Function(PreparationCancellationReason reason)>[];
  Completer<PreparationCancellationReason>? _completer;
  bool _cancelled = false;
  PreparationCancellationReason? _reason;

  bool get isCancelled => _cancelled;

  PreparationCancellationReason? get reason => _reason;

  /// Completes once this token is cancelled.
  Future<PreparationCancellationReason> get cancelled {
    final existing = _completer;
    if (existing != null) return existing.future;
    if (_cancelled)
      return Future<PreparationCancellationReason>.value(_reason!);
    final completer = Completer<PreparationCancellationReason>();
    _completer = completer;
    return completer.future;
  }

  /// Creates a token that fires when this token fires.
  PreparationCancellationToken child() {
    final child = PreparationCancellationToken();
    if (_cancelled) {
      child.cancel(_reason!);
      return child;
    }
    addListener(child.cancel);
    return child;
  }

  void addListener(
    void Function(PreparationCancellationReason reason) listener,
  ) {
    if (_cancelled) {
      listener(_reason!);
      return;
    }
    _listeners.add(listener);
  }

  void removeListener(
    void Function(PreparationCancellationReason reason) listener,
  ) => _listeners.remove(listener);

  void cancel([
    PreparationCancellationReason reason = PreparationCancellationReason.caller,
  ]) {
    if (_cancelled) return;
    _cancelled = true;
    _reason = reason;
    final completer = _completer;
    _completer = null;
    if (completer != null && !completer.isCompleted) completer.complete(reason);
    final listeners = List<void Function(PreparationCancellationReason)>.of(
      _listeners,
    );
    _listeners.clear();
    for (final listener in listeners) {
      listener(reason);
    }
  }
}
