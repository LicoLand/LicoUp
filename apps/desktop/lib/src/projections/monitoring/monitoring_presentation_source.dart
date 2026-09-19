import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/presentation/monitoring/monitoring_projection.dart';
import 'package:licoup/src/presentation/monitoring/monitoring_resources.dart';

int _monitoringSourceIncarnations = 0;

/// F01 renderer-independent source over the monitoring projection owner.
///
/// The wrapped producer remains the application-facing owner. This adapter
/// adds source identity: one epoch per adapter incarnation, monotonic
/// versions, and a single-member consistency group per accepted change so the
/// runtime can admit updates atomically. The observation subscription is
/// established before the initial read, so no producer update can be dropped
/// between the two.
final class MonitoringPresentationSource
    implements PresentationSource<MonitoringProjection> {
  MonitoringPresentationSource({
    required ProjectionSource<MonitoringProjection> projection,
  }) : _projection = projection,
       _epoch = SourceEpoch('monitoring-${++_monitoringSourceIncarnations}');

  final ProjectionSource<MonitoringProjection> _projection;
  final SourceEpoch _epoch;
  final SourceIdentity _identity = const SourceIdentity(
    scope: monitoringPresentationScope,
    stableKey: 'usage',
  );
  final Set<StreamController<SourceChange<MonitoringProjection>>> _listeners =
      <StreamController<SourceChange<MonitoringProjection>>>{};
  StreamSubscription<ProjectionUpdate<MonitoringProjection>>? _subscription;
  ResourceSnapshot<MonitoringProjection>? _installed;
  bool _disposed = false;

  @override
  ResourceFieldGroup<MonitoringProjection> get fieldGroup =>
      monitoringUsageFields;

  @override
  Future<SourceObservation<MonitoringProjection>> open() {
    if (_disposed) {
      return Future<SourceObservation<MonitoringProjection>>.error(
        StateError('monitoring presentation source is disposed'),
      );
    }
    _ensureSubscribed();
    final initial = _snapshotFor(_projection.current);
    final controller = StreamController<SourceChange<MonitoringProjection>>(
      sync: true,
    );
    controller.onCancel = () => _release(controller);
    _listeners.add(controller);
    return Future<SourceObservation<MonitoringProjection>>.value(
      SourceObservation<MonitoringProjection>(
        initial: initial,
        changes: controller.stream,
      ),
    );
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _cancelSubscription();
    for (final controller in _listeners.toList()) {
      // A listener whose stream was never attached never completes its close
      // future; closing is best-effort since disposal is terminal anyway.
      unawaited(controller.close());
    }
    _listeners.clear();
  }

  void _ensureSubscribed() {
    _subscription ??= _projection.changes.listen(_accept);
  }

  Future<void> _cancelSubscription() async {
    final subscription = _subscription;
    _subscription = null;
    await subscription?.cancel();
  }

  void _release(
    StreamController<SourceChange<MonitoringProjection>> controller,
  ) {
    if (!_listeners.remove(controller)) return;
    unawaited(controller.close());
    if (_listeners.isEmpty) unawaited(_cancelSubscription());
  }

  ResourceSnapshot<MonitoringProjection> _snapshotFor(
    MonitoringProjection value,
  ) {
    final installed = _installed;
    if (installed != null && installed.value == value) return installed;
    final version = SourceVersion((installed?.version.value ?? 0) + 1);
    final position = SourcePosition(epoch: _epoch, version: version);
    final group = ConsistencyGroup(
      id: ConsistencyGroupId(
        'monitoring-usage-${version.value}',
        source: _identity,
      ),
      position: position,
      changed: <ChangedFieldGroup>[ChangedFieldGroup.of(fieldGroup)],
    );
    final snapshot = ResourceSnapshot<MonitoringProjection>(
      fieldGroup: fieldGroup,
      epoch: _epoch,
      version: version,
      value: value,
      consistencyGroup: group,
    );
    _installed = snapshot;
    return snapshot;
  }

  void _accept(ProjectionUpdate<MonitoringProjection> update) {
    if (_disposed || _listeners.isEmpty) return;
    final previous = _installed;
    final next = _snapshotFor(update.value);
    if (previous == null || identical(next, previous)) return;
    final group = next.consistencyGroup!;
    final change = SourceChange<MonitoringProjection>(
      snapshot: next,
      base: previous.position,
      group: group,
      trace: update.trace,
    );
    for (final controller in _listeners.toList()) {
      if (!controller.isClosed) controller.add(change);
    }
  }
}
