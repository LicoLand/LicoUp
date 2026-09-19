import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/presentation/agent_hub/agent_hub_projection.dart';
import 'package:licoup/src/presentation/agent_hub/agent_hub_resources.dart';

int _agentHubSourceIncarnations = 0;

/// F01 renderer-independent source over the agent hub projection owner.
///
/// The wrapped producer remains the application-facing owner. This adapter
/// adds source identity: one epoch per adapter incarnation, monotonic
/// versions, and a single-member consistency group per accepted change so the
/// runtime can admit updates atomically. The observation subscription is
/// established before the initial read, so no producer update can be dropped
/// between the two.
final class AgentHubPresentationSource
    implements PresentationSource<AgentHubProjection> {
  AgentHubPresentationSource({
    required ProjectionSource<AgentHubProjection> projection,
  }) : _projection = projection,
       _epoch = SourceEpoch('agent_hub-${++_agentHubSourceIncarnations}');

  final ProjectionSource<AgentHubProjection> _projection;
  final SourceEpoch _epoch;
  final SourceIdentity _identity = const SourceIdentity(
    scope: agentHubPresentationScope,
    stableKey: 'catalog',
  );
  final Set<StreamController<SourceChange<AgentHubProjection>>> _listeners =
      <StreamController<SourceChange<AgentHubProjection>>>{};
  StreamSubscription<ProjectionUpdate<AgentHubProjection>>? _subscription;
  ResourceSnapshot<AgentHubProjection>? _installed;
  bool _disposed = false;

  @override
  ResourceFieldGroup<AgentHubProjection> get fieldGroup =>
      agentHubCatalogFields;

  @override
  Future<SourceObservation<AgentHubProjection>> open() {
    if (_disposed) {
      return Future<SourceObservation<AgentHubProjection>>.error(
        StateError('agent hub presentation source is disposed'),
      );
    }
    _ensureSubscribed();
    final initial = _snapshotFor(_projection.current);
    final controller = StreamController<SourceChange<AgentHubProjection>>(
      sync: true,
    );
    controller.onCancel = () => _release(controller);
    _listeners.add(controller);
    return Future<SourceObservation<AgentHubProjection>>.value(
      SourceObservation<AgentHubProjection>(
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

  void _release(StreamController<SourceChange<AgentHubProjection>> controller) {
    if (!_listeners.remove(controller)) return;
    unawaited(controller.close());
    if (_listeners.isEmpty) unawaited(_cancelSubscription());
  }

  ResourceSnapshot<AgentHubProjection> _snapshotFor(AgentHubProjection value) {
    final installed = _installed;
    if (installed != null && installed.value == value) return installed;
    final version = SourceVersion((installed?.version.value ?? 0) + 1);
    final position = SourcePosition(epoch: _epoch, version: version);
    final group = ConsistencyGroup(
      id: ConsistencyGroupId(
        'agent_hub-catalog-${version.value}',
        source: _identity,
      ),
      position: position,
      changed: <ChangedFieldGroup>[ChangedFieldGroup.of(fieldGroup)],
    );
    final snapshot = ResourceSnapshot<AgentHubProjection>(
      fieldGroup: fieldGroup,
      epoch: _epoch,
      version: version,
      value: value,
      consistencyGroup: group,
    );
    _installed = snapshot;
    return snapshot;
  }

  void _accept(ProjectionUpdate<AgentHubProjection> update) {
    if (_disposed || _listeners.isEmpty) return;
    final previous = _installed;
    final next = _snapshotFor(update.value);
    if (previous == null || identical(next, previous)) return;
    final group = next.consistencyGroup!;
    final change = SourceChange<AgentHubProjection>(
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
