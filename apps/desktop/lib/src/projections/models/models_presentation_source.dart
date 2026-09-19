import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/presentation/models/models_projection.dart';
import 'package:licoup/src/presentation/models/models_resources.dart';

int _modelsSourceIncarnations = 0;

/// F01 renderer-independent source over the models projection owner.
///
/// The wrapped producer remains the application-facing owner. This adapter
/// adds source identity: one epoch per adapter incarnation, monotonic
/// versions, and a single-member consistency group per accepted change so the
/// runtime can admit updates atomically. The observation subscription is
/// established before the initial read, so no producer update can be dropped
/// between the two.
final class ModelsPresentationSource
    implements PresentationSource<ModelsProjection> {
  ModelsPresentationSource({
    required ProjectionSource<ModelsProjection> projection,
  }) : _projection = projection,
       _epoch = SourceEpoch('models-${++_modelsSourceIncarnations}');

  final ProjectionSource<ModelsProjection> _projection;
  final SourceEpoch _epoch;
  final SourceIdentity _identity = const SourceIdentity(
    scope: modelsPresentationScope,
    stableKey: 'catalog',
  );
  final Set<StreamController<SourceChange<ModelsProjection>>> _listeners =
      <StreamController<SourceChange<ModelsProjection>>>{};
  StreamSubscription<ProjectionUpdate<ModelsProjection>>? _subscription;
  ResourceSnapshot<ModelsProjection>? _installed;
  bool _disposed = false;

  @override
  ResourceFieldGroup<ModelsProjection> get fieldGroup => modelsCatalogFields;

  @override
  Future<SourceObservation<ModelsProjection>> open() {
    if (_disposed) {
      return Future<SourceObservation<ModelsProjection>>.error(
        StateError('models presentation source is disposed'),
      );
    }
    _ensureSubscribed();
    final initial = _snapshotFor(_projection.current);
    final controller = StreamController<SourceChange<ModelsProjection>>(
      sync: true,
    );
    controller.onCancel = () => _release(controller);
    _listeners.add(controller);
    return Future<SourceObservation<ModelsProjection>>.value(
      SourceObservation<ModelsProjection>(
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

  void _release(StreamController<SourceChange<ModelsProjection>> controller) {
    if (!_listeners.remove(controller)) return;
    unawaited(controller.close());
    if (_listeners.isEmpty) unawaited(_cancelSubscription());
  }

  ResourceSnapshot<ModelsProjection> _snapshotFor(ModelsProjection value) {
    final installed = _installed;
    if (installed != null && installed.value == value) return installed;
    final version = SourceVersion((installed?.version.value ?? 0) + 1);
    final position = SourcePosition(epoch: _epoch, version: version);
    final group = ConsistencyGroup(
      id: ConsistencyGroupId(
        'models-catalog-${version.value}',
        source: _identity,
      ),
      position: position,
      changed: <ChangedFieldGroup>[ChangedFieldGroup.of(fieldGroup)],
    );
    final snapshot = ResourceSnapshot<ModelsProjection>(
      fieldGroup: fieldGroup,
      epoch: _epoch,
      version: version,
      value: value,
      consistencyGroup: group,
    );
    _installed = snapshot;
    return snapshot;
  }

  void _accept(ProjectionUpdate<ModelsProjection> update) {
    if (_disposed || _listeners.isEmpty) return;
    final previous = _installed;
    final next = _snapshotFor(update.value);
    if (previous == null || identical(next, previous)) return;
    final group = next.consistencyGroup!;
    final change = SourceChange<ModelsProjection>(
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
