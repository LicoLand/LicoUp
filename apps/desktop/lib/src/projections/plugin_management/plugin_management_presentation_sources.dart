import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/presentation/plugin_management/plugin_management_inputs.dart';
import 'package:licoup/src/presentation/plugin_management/plugin_management_projection.dart';

const pluginManagementScope = ResourceScope('plugin-management');

/// Stable resource identity for the plugin catalog region.
final pluginCatalogFieldGroup = ResourceFieldGroup<PluginCatalogInputs>(
  resource: ResourceKey(scope: pluginManagementScope, stableKey: 'plugins'),
  name: 'inputs',
);

/// Stable resource identity for the optional collaboration region.
final pluginCollaborationFieldGroup =
    ResourceFieldGroup<PluginCollaborationInputs>(
      resource: ResourceKey(
        scope: pluginManagementScope,
        stableKey: 'collaboration',
      ),
      name: 'inputs',
    );

/// Catalog slice of the combined projection.
///
/// The producer derives the combined phase and notice from the adapter plugin
/// domain alone, so this slice never carries collaboration state.
PluginCatalogInputs pluginCatalogSlice(PluginManagementProjection projection) =>
    PluginCatalogInputs(
      plugins: projection.plugins,
      phase: projection.phase,
      notice: projection.notice,
    );

/// Optional collaboration slice of the combined projection.
PluginCollaborationInputs pluginCollaborationSlice(
  PluginManagementProjection projection,
) => PluginCollaborationInputs(
  collaboration: projection.collaboration,
  phase: projection.collaboration.phase,
  notice: projection.collaboration.notice,
);

int _pluginManagementEpochCounter = 0;

/// Creates the plugin catalog presentation source over the plugin management
/// projection owner.
PluginManagementRegionPresentationSource<PluginCatalogInputs>
pluginCatalogPresentationSource(
  ProjectionSource<PluginManagementProjection> source,
) => PluginManagementRegionPresentationSource<PluginCatalogInputs>(
  fieldGroup: pluginCatalogFieldGroup,
  source: source,
  select: pluginCatalogSlice,
  epochId: 'plugin-management-catalog-${_pluginManagementEpochCounter++}',
);

/// Creates the optional collaboration presentation source over the plugin
/// management projection owner.
PluginManagementRegionPresentationSource<PluginCollaborationInputs>
pluginCollaborationPresentationSource(
  ProjectionSource<PluginManagementProjection> source,
) => PluginManagementRegionPresentationSource<PluginCollaborationInputs>(
  fieldGroup: pluginCollaborationFieldGroup,
  source: source,
  select: pluginCollaborationSlice,
  epochId: 'plugin-management-collaboration-${_pluginManagementEpochCounter++}',
);

/// Presentation-source adapter over the plugin management projection owner.
///
/// The wrapped projection stays the single owner of the combined state; this
/// adapter selects one domain slice and re-issues it with epoch/version and
/// base-matched changes for the presentation runtime. A producer publish that
/// leaves the selected slice equal emits nothing, so an unrelated region keeps
/// its installed snapshot.
final class PluginManagementRegionPresentationSource<T>
    implements PresentationSource<T> {
  PluginManagementRegionPresentationSource({
    required this.fieldGroup,
    required ProjectionSource<PluginManagementProjection> source,
    required T Function(PluginManagementProjection projection) select,
    required String epochId,
  }) : _source = source,
       _select = select,
       _epoch = SourceEpoch(epochId);

  @override
  final ResourceFieldGroup<T> fieldGroup;

  final ProjectionSource<PluginManagementProjection> _source;
  final T Function(PluginManagementProjection projection) _select;
  final SourceEpoch _epoch;
  final Set<_PluginRegionObservation<T>> _observations =
      <_PluginRegionObservation<T>>{};
  int _version = 0;
  bool _disposed = false;

  @override
  Future<SourceObservation<T>> open() {
    if (_disposed) {
      throw StateError('plugin management presentation source disposed');
    }
    _version += 1;
    final observation = _PluginRegionObservation<T>(
      this,
      SourcePosition(epoch: _epoch, version: SourceVersion(_version)),
    );
    _observations.add(observation);
    return observation.open();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final observation in List<_PluginRegionObservation<T>>.of(
      _observations,
    )) {
      await observation.close();
    }
    _observations.clear();
  }
}

final class _PluginRegionObservation<T> {
  _PluginRegionObservation(this._owner, this._base);

  final PluginManagementRegionPresentationSource<T> _owner;
  final SourcePosition _base;
  final StreamController<SourceChange<T>> _changes =
      StreamController<SourceChange<T>>(sync: true);
  late final StreamSubscription<ProjectionUpdate<PluginManagementProjection>>
  _upstream;
  late T _value;
  late SourcePosition _installed;
  bool _closed = false;

  Future<SourceObservation<T>> open() {
    // Subscribe before reading the current slice so no producer update is lost
    // between the initial read and the change stream.
    _upstream = _owner._source.changes.listen(
      _onUpdate,
      onDone: () => unawaited(close()),
    );
    _value = _owner._select(_owner._source.current);
    _installed = _base;
    _changes.onCancel = close;
    return Future<SourceObservation<T>>.value(
      SourceObservation<T>(
        initial: ResourceSnapshot<T>(
          fieldGroup: _owner.fieldGroup,
          epoch: _base.epoch,
          version: _base.version,
          value: _value,
        ),
        changes: _changes.stream,
      ),
    );
  }

  void _onUpdate(ProjectionUpdate<PluginManagementProjection> update) {
    if (_closed || _changes.isClosed) return;
    final next = _owner._select(update.value);
    if (next == _value) return;
    _owner._version += 1;
    final position = SourcePosition(
      epoch: _owner._epoch,
      version: SourceVersion(_owner._version),
    );
    final group = ConsistencyGroup(
      id: ConsistencyGroupId(
        '${_owner.fieldGroup.resource.stableKey}-${position.version.value}',
        source: SourceIdentity(
          scope: _owner.fieldGroup.resource.scope,
          stableKey: _owner.fieldGroup.resource.stableKey,
        ),
      ),
      position: position,
      changed: <ChangedFieldGroup>[ChangedFieldGroup.of(_owner.fieldGroup)],
    );
    _changes.add(
      SourceChange<T>(
        snapshot: ResourceSnapshot<T>(
          fieldGroup: _owner.fieldGroup,
          epoch: position.epoch,
          version: position.version,
          value: next,
          consistencyGroup: group,
        ),
        base: _installed,
        group: group,
        trace: update.trace,
      ),
    );
    _value = next;
    _installed = position;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _owner._observations.remove(this);
    await _upstream.cancel();
    if (!_changes.isClosed) await _changes.close();
  }
}
