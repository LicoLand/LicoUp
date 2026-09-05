import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/frontend/binding/causal_frame_telemetry.dart';

/// Composition-owned trace boundary between semantic producers and Flutter.
///
/// Every source update receives a trace before any renderer can observe it.
/// Runtime-originated updates begin a local trace here; renderer-originated
/// updates retain the trace carried through Application state.
final class CausalProjectionSourceRegistry {
  CausalProjectionSourceRegistry(this._telemetry);

  final CausalFrameTelemetry? _telemetry;
  final List<_DisposableTracedSource> _sources = [];
  bool _disposed = false;

  ProjectionSource<T> wrap<T>(ProjectionSource<T> source) {
    final telemetry = _telemetry;
    if (telemetry == null) return source;
    if (_disposed) throw StateError('causal_projection_registry_disposed');
    final traced = _TracedProjectionSource<T>(source, telemetry);
    _sources.add(traced);
    return traced;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final source in _sources.reversed) {
      await source.dispose();
    }
    _sources.clear();
  }
}

abstract interface class _DisposableTracedSource {
  Future<void> dispose();
}

final class _TracedProjectionSource<T>
    implements ProjectionSource<T>, _DisposableTracedSource {
  _TracedProjectionSource(this._source, this._telemetry) {
    _subscription = _source.changes.listen(_handleUpdate);
  }

  final ProjectionSource<T> _source;
  final CausalFrameTelemetry _telemetry;
  final StreamController<ProjectionUpdate<T>> _changes =
      StreamController<ProjectionUpdate<T>>.broadcast(sync: true);
  late final StreamSubscription<ProjectionUpdate<T>> _subscription;
  bool _disposed = false;

  @override
  T get current => _source.current;

  @override
  Stream<ProjectionUpdate<T>> get changes => _changes.stream;

  void _handleUpdate(ProjectionUpdate<T> update) {
    if (_disposed) return;
    final runtimeOriginated = update.trace == null;
    final trace = _telemetry.projectionEmitted(trace: update.trace);
    if (!_changes.hasListener) {
      // This source owns cleanup only for a runtime trace it created here.
      // A propagated renderer trace may fan out to several independently
      // scoped projections; an unobserved sibling must not close it before an
      // observed projection reaches Flutter.
      if (update.trace == null) {
        _telemetry.discardTrace(
          trace,
          CausalTelemetryUnavailableReason.projectionNotObserved,
        );
      }
      return;
    }
    _changes.add(ProjectionUpdate<T>(update.value, trace: trace));
    if (runtimeOriginated) {
      _telemetry.discardIfNotReceived(
        trace,
        CausalTelemetryUnavailableReason.frameNotObserved,
      );
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _subscription.cancel();
    await _changes.close();
  }
}
