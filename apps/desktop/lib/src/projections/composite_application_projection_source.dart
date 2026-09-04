import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/application/state/application_signal.dart';
import 'package:licoup/src/projections/close_broadcast_controller.dart';

typedef CompositeProjectionReader<T> = T Function();

/// Equality-suppressing projection over the smallest Application owners that
/// jointly define one renderer-facing feature snapshot.
final class CompositeApplicationProjectionSource<T>
    implements ProjectionSource<T> {
  CompositeApplicationProjectionSource({
    required Iterable<Stream<ApplicationChange>> changes,
    required CompositeProjectionReader<T> read,
  }) : _read = read,
       _current = read() {
    _subscriptions = [
      for (final stream in changes) stream.listen(_onApplicationChange),
    ];
  }

  final CompositeProjectionReader<T> _read;
  final StreamController<ProjectionUpdate<T>> _updates =
      StreamController<ProjectionUpdate<T>>.broadcast(sync: true);
  late final List<StreamSubscription<ApplicationChange>> _subscriptions;
  T _current;
  bool _disposed = false;

  @override
  T get current => _current;

  @override
  Stream<ProjectionUpdate<T>> get changes => _updates.stream;

  void refresh([ApplicationCause? cause]) {
    _onApplicationChange(ApplicationChange(cause: cause));
  }

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
    await Future.wait([
      for (final subscription in _subscriptions) subscription.cancel(),
    ]);
    await closeBroadcastController(_updates);
  }
}
