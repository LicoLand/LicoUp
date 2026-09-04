import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/presentation/environment/environment_projection.dart';
import 'package:licoup/src/projections/close_broadcast_controller.dart';

/// Composition-owned source for renderer-collected environment values.
final class EnvironmentProjectionSource
    implements ProjectionSource<EnvironmentProjection> {
  EnvironmentProjectionSource(
    EnvironmentState initial, {
    EnvironmentProjection Function(EnvironmentState state) resolver =
        resolveEnvironmentProjection,
  }) : _resolver = resolver,
       _state = initial,
       _current = resolver(initial);

  final StreamController<ProjectionUpdate<EnvironmentProjection>> _changes =
      StreamController<ProjectionUpdate<EnvironmentProjection>>.broadcast(
        sync: true,
      );
  EnvironmentProjection _current;
  EnvironmentState _state;
  final EnvironmentProjection Function(EnvironmentState state) _resolver;
  bool _disposed = false;

  @override
  EnvironmentProjection get current => _current;

  @override
  Stream<ProjectionUpdate<EnvironmentProjection>> get changes =>
      _changes.stream;

  bool replace(EnvironmentState state, {TraceContext? trace}) {
    if (_disposed || state == _state) return false;
    _state = state;
    final value = _resolver(state);
    if (value == _current) return false;
    _current = value;
    _changes.add(ProjectionUpdate(value, trace: trace));
    return true;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await closeBroadcastController(_changes);
  }
}
