import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/presentation/skill_hub/skill_hub_inputs.dart';
import 'package:licoup/src/presentation/skill_hub/skill_hub_projection.dart';

/// Stable resource identity for the skill hub catalog region.
final skillHubCatalogFieldGroup = ResourceFieldGroup<SkillHubCatalogInputs>(
  resource: ResourceKey(
    scope: const ResourceScope('skill-hub'),
    stableKey: 'catalog',
  ),
  name: 'inputs',
);

int _epochCounter = 0;

/// Creates the catalog presentation source over the skill hub projection.
SkillHubCatalogPresentationSource skillHubCatalogPresentationSource(
  ProjectionSource<SkillHubProjection> source,
) {
  return SkillHubCatalogPresentationSource(
    fieldGroup: skillHubCatalogFieldGroup,
    source: source,
    epochId: 'skill-hub-catalog-${_epochCounter++}',
  );
}

/// Presentation-source adapter over the existing skill hub projection.
///
/// The wrapped projection remains the single owner of the hub state; this
/// adapter maps it onto the narrow catalog slice, drops republishes whose slice
/// is unchanged, and re-issues changed slices with epoch/version and
/// base-matched changes for the presentation runtime. The upstream projection
/// is subscribed only while an observation is open.
final class SkillHubCatalogPresentationSource
    implements PresentationSource<SkillHubCatalogInputs> {
  SkillHubCatalogPresentationSource({
    required this.fieldGroup,
    required ProjectionSource<SkillHubProjection> source,
    required String epochId,
  }) : _source = source,
       _epoch = SourceEpoch(epochId);

  @override
  final ResourceFieldGroup<SkillHubCatalogInputs> fieldGroup;

  final ProjectionSource<SkillHubProjection> _source;
  final SourceEpoch _epoch;
  final List<_SkillHubCatalogOpen> _opens = <_SkillHubCatalogOpen>[];
  int _version = 0;
  bool _disposed = false;

  @override
  Future<SourceObservation<SkillHubCatalogInputs>> open() async {
    if (_disposed) {
      throw StateError('skill hub catalog presentation source disposed');
    }
    _version += 1;
    final position = SourcePosition(
      epoch: _epoch,
      version: SourceVersion(_version),
    );
    final changes = StreamController<SourceChange<SkillHubCatalogInputs>>(
      sync: true,
    );
    final open = _SkillHubCatalogOpen(changes);
    _opens.add(open);
    // The subscription is established before the initial read, so a hub
    // update cannot slip between the read and the change stream.
    open.subscription = _source.changes.listen(
      (update) => _emit(open, update),
      onDone: () {
        if (!changes.isClosed) unawaited(changes.close());
      },
    );
    changes.onCancel = () {
      _opens.remove(open);
      unawaited(open.release());
    };
    final value = skillHubCatalogInputsOf(_source.current);
    open.installedPosition = position;
    open.installedValue = value;
    return SourceObservation<SkillHubCatalogInputs>(
      initial: ResourceSnapshot<SkillHubCatalogInputs>(
        fieldGroup: fieldGroup,
        epoch: position.epoch,
        version: position.version,
        value: value,
      ),
      changes: changes.stream,
    );
  }

  /// Releases every open observation and its upstream subscription.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final open in List<_SkillHubCatalogOpen>.of(_opens)) {
      await open.close();
    }
    _opens.clear();
  }

  void _emit(
    _SkillHubCatalogOpen open,
    ProjectionUpdate<SkillHubProjection> update,
  ) {
    if (_disposed || open.released || open.changes.isClosed) return;
    final installed = open.installedPosition;
    if (installed == null) return;
    final value = skillHubCatalogInputsOf(update.value);
    if (value == open.installedValue) return;
    _version += 1;
    final position = SourcePosition(
      epoch: _epoch,
      version: SourceVersion(_version),
    );
    final group = ConsistencyGroup(
      id: ConsistencyGroupId(
        '${fieldGroup.resource.stableKey}-${position.version.value}',
        source: SourceIdentity(
          scope: fieldGroup.resource.scope,
          stableKey: fieldGroup.resource.stableKey,
        ),
      ),
      position: position,
      changed: <ChangedFieldGroup>[ChangedFieldGroup.of(fieldGroup)],
    );
    final snapshot = ResourceSnapshot<SkillHubCatalogInputs>(
      fieldGroup: fieldGroup,
      epoch: position.epoch,
      version: position.version,
      value: value,
      consistencyGroup: group,
    );
    open.installedPosition = position;
    open.installedValue = value;
    open.changes.add(
      SourceChange<SkillHubCatalogInputs>(
        snapshot: snapshot,
        base: installed,
        group: group,
        trace: update.trace,
      ),
    );
  }
}

final class _SkillHubCatalogOpen {
  _SkillHubCatalogOpen(this.changes);

  final StreamController<SourceChange<SkillHubCatalogInputs>> changes;
  StreamSubscription<ProjectionUpdate<SkillHubProjection>>? subscription;
  SourcePosition? installedPosition;
  SkillHubCatalogInputs? installedValue;
  bool _released = false;

  bool get released => _released;

  Future<void> release() async {
    if (_released) return;
    _released = true;
    await subscription?.cancel();
  }

  Future<void> close() async {
    await release();
    // A never-observed controller completes its close future only once a
    // listener drains it, so the release does not wait for that future.
    if (!changes.isClosed) unawaited(changes.close());
  }
}
