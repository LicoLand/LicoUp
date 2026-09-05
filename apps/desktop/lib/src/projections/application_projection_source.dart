import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/application/state/application_signal.dart';
import 'package:licoup/src/projections/close_broadcast_controller.dart';

typedef ProjectionReader<T> = T Function();

/// Equality-suppressing projection over one smallest Application owner signal.
final class ApplicationProjectionSource<T> implements ProjectionSource<T> {
  ApplicationProjectionSource({
    required Stream<ApplicationChange> changes,
    required ProjectionReader<T> read,
  }) : _read = read,
       _current = read() {
    _subscription = changes.listen(_onApplicationChange);
  }

  final ProjectionReader<T> _read;
  final StreamController<ProjectionUpdate<T>> _updates =
      StreamController<ProjectionUpdate<T>>.broadcast(sync: true);
  late final StreamSubscription<ApplicationChange> _subscription;
  T _current;
  bool _disposed = false;

  @override
  T get current => _current;

  @override
  Stream<ProjectionUpdate<T>> get changes => _updates.stream;

  void _onApplicationChange(ApplicationChange change) {
    if (_disposed) return;
    final next = _read();
    if (next == _current) return;
    _current = next;
    _updates.add(
      ProjectionUpdate(
        next,
        trace: change.cause?.traceId == null
            ? null
            : TraceContext(traceId: change.cause!.traceId),
      ),
    );
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _subscription.cancel();
    await closeBroadcastController(_updates);
  }
}
