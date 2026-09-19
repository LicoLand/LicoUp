import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/application/state/application_signal.dart';
import 'package:licoup/src/contracts/appearance/appearance_preset_config.dart';
import 'package:licoup/src/contracts/presentation/layout_selection_status.dart';
import 'package:licoup/src/presentation/environment/locale_preferences.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';
import 'package:licoup/src/presentation/settings/settings_inputs.dart';
import 'package:licoup/src/presentation/settings/settings_projection.dart';

/// One typed settings region: its stable resource identity and the pure read
/// that computes the region value from the application controller.
final class SettingsPresentationRegion<T> {
  const SettingsPresentationRegion({
    required this.fieldGroup,
    required this.read,
  });

  final ResourceFieldGroup<T> fieldGroup;
  final T Function(ClientController controller) read;
}

/// Source-side publisher for the settings presentation regions.
///
/// The hub subscribes to the application owners only while at least one region
/// has an open observation, and recomputes only the regions that are currently
/// observed. Unchanged regions keep their installed snapshot, so a locale
/// update never rebuilds the appearance region and an appearance update never
/// rebuilds layout. Every publish event forms one consistency group covering
/// the regions that actually changed.
final class SettingsPresentationHub {
  SettingsPresentationHub(this._controller);

  final ClientController _controller;
  final Map<Object, _SettingsRegionState<Object?>> _observed =
      <Object, _SettingsRegionState<Object?>>{};
  final List<StreamSubscription<ApplicationChange>> _subscriptions =
      <StreamSubscription<ApplicationChange>>[];
  late final SourceEpoch _epoch = SourceEpoch('settings-${_epochCounter++}');
  int _version = 0;
  bool _disposed = false;

  static int _epochCounter = 0;

  static final settingsGeneralRegion = SettingsPresentationRegion(
    fieldGroup: ResourceFieldGroup<SettingsGeneralInputs>(
      resource: ResourceKey(
        scope: const ResourceScope('settings'),
        stableKey: 'general',
      ),
      name: 'inputs',
    ),
    read: _readGeneral,
  );

  static final settingsAppearanceRegion = SettingsPresentationRegion(
    fieldGroup: ResourceFieldGroup<SettingsAppearanceInputs>(
      resource: ResourceKey(
        scope: const ResourceScope('settings'),
        stableKey: 'appearance',
      ),
      name: 'inputs',
    ),
    read: _readAppearance,
  );

  static final settingsLayoutRegion = SettingsPresentationRegion(
    fieldGroup: ResourceFieldGroup<SettingsLayoutInputs>(
      resource: ResourceKey(
        scope: const ResourceScope('settings'),
        stableKey: 'layout',
      ),
      name: 'inputs',
    ),
    read: _readLayout,
  );

  static final settingsStorageRegion = SettingsPresentationRegion(
    fieldGroup: ResourceFieldGroup<SettingsStorageInputs>(
      resource: ResourceKey(
        scope: const ResourceScope('settings'),
        stableKey: 'storage',
      ),
      name: 'inputs',
    ),
    read: _readStorage,
  );

  static final settingsUpdateRegion = SettingsPresentationRegion(
    fieldGroup: ResourceFieldGroup<SettingsUpdateInputs>(
      resource: ResourceKey(
        scope: const ResourceScope('settings'),
        stableKey: 'update',
      ),
      name: 'inputs',
    ),
    read: _readUpdate,
  );

  static final settingsArchivedRegion = SettingsPresentationRegion(
    fieldGroup: ResourceFieldGroup<SettingsArchivedInputs>(
      resource: ResourceKey(
        scope: const ResourceScope('settings'),
        stableKey: 'archived',
      ),
      name: 'inputs',
    ),
    read: _readArchived,
  );

  static final settingsLogExportRegion = SettingsPresentationRegion(
    fieldGroup: ResourceFieldGroup<SettingsLogExportInputs>(
      resource: ResourceKey(
        scope: const ResourceScope('settings'),
        stableKey: 'log-export',
      ),
      name: 'inputs',
    ),
    read: _readLogExport,
  );

  PresentationSource<SettingsGeneralInputs> generalSource() =>
      _SettingsRegionSource<SettingsGeneralInputs>(this, settingsGeneralRegion);

  PresentationSource<SettingsAppearanceInputs> appearanceSource() =>
      _SettingsRegionSource<SettingsAppearanceInputs>(
        this,
        settingsAppearanceRegion,
      );

  PresentationSource<SettingsLayoutInputs> layoutSource() =>
      _SettingsRegionSource<SettingsLayoutInputs>(this, settingsLayoutRegion);

  PresentationSource<SettingsStorageInputs> storageSource() =>
      _SettingsRegionSource<SettingsStorageInputs>(this, settingsStorageRegion);

  PresentationSource<SettingsUpdateInputs> updateSource() =>
      _SettingsRegionSource<SettingsUpdateInputs>(this, settingsUpdateRegion);

  PresentationSource<SettingsArchivedInputs> archivedSource() =>
      _SettingsRegionSource<SettingsArchivedInputs>(
        this,
        settingsArchivedRegion,
      );

  PresentationSource<SettingsLogExportInputs> logExportSource() =>
      _SettingsRegionSource<SettingsLogExportInputs>(
        this,
        settingsLogExportRegion,
      );

  /// Recomputes observed regions after an action whose effects are not
  /// signaled through an owner change stream.
  void refresh([ApplicationCause? cause]) => _publish(cause);

  Future<SourceObservation<T>> _open<T>(
    SettingsPresentationRegion<T> region,
  ) async {
    if (_disposed) {
      throw StateError('settings presentation hub disposed');
    }
    final key = Object();
    final state = _SettingsRegionState<T>(this, region, () => _close(key));
    _observed[key] = state as _SettingsRegionState<Object?>;
    if (_observed.length == 1) {
      _subscribe();
    }
    // The subscription is established before the initial read, so an owner
    // change cannot slip between the read and the update stream.
    final initial = state._open();
    return SourceObservation<T>(
      initial: initial,
      changes: state._changes.stream,
    );
  }

  void _close(Object key) {
    final state = _observed.remove(key);
    state?._close();
    if (_observed.isEmpty) {
      _unsubscribe();
    }
  }

  void _subscribe() {
    _subscriptions.addAll(<StreamSubscription<ApplicationChange>>[
      _controller.appearancePreferenceOwner.changes.listen(_onChange),
      _controller.localePreferenceOwner.changes.listen(_onChange),
      _controller.clientUpdateController.changes.listen(_onChange),
      _controller.clientLogExportController.changes.listen(_onChange),
      _controller.clientConversationController.changes.listen(_onChange),
      _controller.catalogConvergenceController.changes.listen(_onChange),
      _controller.layoutManager.changes.listen(_onChange),
    ]);
  }

  void _unsubscribe() {
    for (final subscription in _subscriptions.reversed) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
  }

  void _onChange(ApplicationChange change) => _publish(change.cause);

  void _publish(ApplicationCause? cause) {
    if (_disposed || _observed.isEmpty) return;
    final emissions = <_SettingsRegionEmission>[];
    for (final state in _observed.values) {
      final next = state._readNext();
      if (state._hasValue && next == state._value) continue;
      emissions.add(_SettingsRegionEmission(state, next));
    }
    if (emissions.isEmpty) return;
    _version += 1;
    final position = SourcePosition(
      epoch: _epoch,
      version: SourceVersion(_version),
    );
    final group = ConsistencyGroup(
      id: ConsistencyGroupId(
        'settings-${position.version.value}',
        source: const SourceIdentity(
          scope: ResourceScope('settings'),
          stableKey: 'settings-hub',
        ),
      ),
      position: position,
      changed: <ChangedFieldGroup>[
        for (final emission in emissions)
          ChangedFieldGroup(
            resource: emission.state._fieldGroup.resource,
            name: emission.state._fieldGroup.name,
          ),
      ],
    );
    final trace = cause?.traceId == null
        ? null
        : TraceContext(traceId: cause!.traceId);
    for (final emission in emissions) {
      emission.state._emit(position, group, emission.value, trace);
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    // Closing a region fires its controller's onCancel, which removes it from
    // _observed — iterate a snapshot so disposal cannot mutate the map mid-loop.
    for (final state in _observed.values.toList()) {
      state._close();
    }
    _observed.clear();
    for (final subscription in _subscriptions.reversed) {
      await subscription.cancel();
    }
    _subscriptions.clear();
  }

  T _read<T>(SettingsPresentationRegion<T> region) => region.read(_controller);

  SourcePosition get _currentPosition =>
      SourcePosition(epoch: _epoch, version: SourceVersion(_version));

  static SettingsGeneralInputs _readGeneral(ClientController controller) {
    return SettingsGeneralInputs(
      localeChoices: [
        for (final preference in LocalePreference.values)
          PresentationChoice(
            id: preference,
            label: preference,
            selected:
                LocalePreference.normalize(controller.localePreference) ==
                preference,
          ),
      ],
    );
  }

  static SettingsAppearanceInputs _readAppearance(ClientController controller) {
    return SettingsAppearanceInputs(
      appearancePresetId: controller.appearancePresetId,
      appearancePresets: [
        for (final config in controller.appearancePresetConfigs)
          SettingsAppearancePresetProjection(
            id: config.id,
            englishLabel: config.labelFor(),
            chineseLabel: config.labelFor('zh-CN'),
            mode: switch (config.mode) {
              AppearancePresetMode.system => SettingsAppearanceMode.system,
              AppearancePresetMode.light => SettingsAppearanceMode.light,
              AppearancePresetMode.dark => SettingsAppearanceMode.dark,
            },
            lightPresetId: config.lightPresetId ?? '',
            darkPresetId: config.darkPresetId ?? '',
          ),
      ],
      appearancePresetDirectoryPath: controller.appearancePresetDirectoryPath,
      appearancePresetLoadErrorCount:
          controller.appearancePresetLoadErrors.length,
      reduceMotion: controller.reduceMotion,
      loadingEffectId: controller.loadingEffectId,
    );
  }

  static SettingsLayoutInputs _readLayout(ClientController controller) {
    final layout = controller.layoutManager;
    final layoutState = layout.state;
    return SettingsLayoutInputs(
      layoutChoices: [
        for (final profile in layout.catalog.profiles)
          PresentationChoice(
            id: profile.id.value,
            label: profile.label.english,
            description: profile.description.english,
            selected: profile.id == layoutState.effectiveId,
            enabled:
                layoutState.status != LayoutSelectionStatus.committing &&
                profile.selectable,
          ),
      ],
      layoutPhase: switch (layoutState.status) {
        LayoutSelectionStatus.loading => PresentationPhase.loading,
        LayoutSelectionStatus.committing => PresentationPhase.applying,
        LayoutSelectionStatus.stable => PresentationPhase.ready,
        LayoutSelectionStatus.error => PresentationPhase.failed,
      },
      layoutFailureReasonCode: layoutState.errorCode?.name ?? '',
    );
  }

  static SettingsStorageInputs _readStorage(ClientController controller) {
    return SettingsStorageInputs(
      portableDataPath: controller.portableDataPath,
      snapshotRootPath: controller.snapshotRootDraft,
      savingSnapshotRoot: controller.isSavingSnapshotRoot,
    );
  }

  static SettingsUpdateInputs _readUpdate(ClientController controller) {
    final update = controller.clientUpdateStatus;
    return SettingsUpdateInputs(
      status: SettingsClientUpdateProjection(
        phase: update.phase,
        runningVersion: update.runningVersion,
        runningReleaseTrack: update.runningReleaseTrack,
        targetReleaseTrack: update.targetReleaseTrack,
        availableVersion: update.availableVersion,
        githubReleaseUrl: update.githubReleaseUrl,
        artifactSha256: update.artifactSha256,
        updateAvailable: update.updateAvailable,
        errorCode: update.errorCode,
      ),
      repository: controller.clientUpdateRepo,
    );
  }

  static SettingsArchivedInputs _readArchived(ClientController controller) {
    final conversations = controller.clientConversationController;
    final failure = conversations.failureCode.trim();
    return SettingsArchivedInputs(
      archivedConversations: [
        for (final conversation in conversations.archivedConversations)
          ArchivedConversationProjection(
            id: conversation.id,
            title: conversation.title,
            isGroup: conversation.isGroup,
            membershipCount: conversation.membershipCount,
            updatedAtUnixMs: conversation.updatedAtUnixMs,
          ),
      ],
      loading: conversations.loading,
      notice: failure.isEmpty
          ? null
          : PresentationNotice(
              id: 'settings-conversation-${conversations.failureStage}',
              title: 'Settings action failed',
              message: 'Review the action and try again.',
              severity: PresentationNoticeSeverity.error,
              reasonCode: failure,
            ),
    );
  }

  static SettingsLogExportInputs _readLogExport(ClientController controller) {
    return SettingsLogExportInputs(
      path: controller.clientLogExportPath,
      busy: controller.isExportingClientLogs,
    );
  }
}

final class _SettingsRegionEmission {
  const _SettingsRegionEmission(this.state, this.value);

  final _SettingsRegionState<Object?> state;
  final Object? value;
}

final class _SettingsRegionSource<T> implements PresentationSource<T> {
  const _SettingsRegionSource(this._hub, this._region);

  final SettingsPresentationHub _hub;
  final SettingsPresentationRegion<T> _region;

  @override
  ResourceFieldGroup<T> get fieldGroup => _region.fieldGroup;

  @override
  Future<SourceObservation<T>> open() => _hub._open(_region);
}

final class _SettingsRegionState<T> {
  _SettingsRegionState(this._hub, this._region, this._onCancel);

  final SettingsPresentationHub _hub;
  final SettingsPresentationRegion<T> _region;
  final void Function() _onCancel;
  late final StreamController<SourceChange<T>> _changes =
      StreamController<SourceChange<T>>(sync: true, onCancel: _onCancel);
  T? _value;
  SourcePosition? _position;
  bool _hasValue = false;

  ResourceFieldGroup<T> get _fieldGroup => _region.fieldGroup;

  ResourceSnapshot<T> _open() {
    final value = _hub._read(_region);
    final position = _hub._currentPosition;
    _value = value;
    _position = position;
    _hasValue = true;
    return ResourceSnapshot<T>(
      fieldGroup: _region.fieldGroup,
      epoch: position.epoch,
      version: position.version,
      value: value,
    );
  }

  Object? _readNext() => _hub._read(_region);

  void _emit(
    SourcePosition position,
    ConsistencyGroup group,
    Object? value,
    TraceContext? trace,
  ) {
    if (_changes.isClosed || !_hasValue) return;
    final typed = value as T;
    final base = _position!;
    final snapshot = ResourceSnapshot<T>(
      fieldGroup: _region.fieldGroup,
      epoch: position.epoch,
      version: position.version,
      value: typed,
      consistencyGroup: group,
    );
    _value = typed;
    _position = position;
    _changes.add(
      SourceChange<T>(
        snapshot: snapshot,
        base: base,
        group: group,
        trace: trace,
      ),
    );
  }

  void _close() {
    if (_changes.isClosed) return;
    unawaited(_changes.close());
  }
}

/// Presentation-source adapter over an existing value-shaped application
/// source. The wrapped source remains the single owner of the underlying
/// state; this adapter only re-issues its values with epoch/version and
/// base-matched changes for the presentation runtime.
final class SettingsValuePresentationSource<T>
    implements PresentationSource<T> {
  SettingsValuePresentationSource({
    required this.fieldGroup,
    required ProjectionSource<T> source,
    required String epochId,
  }) : _source = source,
       _epoch = SourceEpoch(epochId);

  @override
  final ResourceFieldGroup<T> fieldGroup;

  final ProjectionSource<T> _source;
  final SourceEpoch _epoch;
  int _version = 0;

  @override
  Future<SourceObservation<T>> open() async {
    _version += 1;
    final position = SourcePosition(
      epoch: _epoch,
      version: SourceVersion(_version),
    );
    var installed = position;
    final changes = StreamController<SourceChange<T>>(sync: true);
    // Subscribe before reading the current value so no update is lost between
    // the initial read and the change stream.
    final subscription = _source.changes.listen(
      (update) {
        if (changes.isClosed) return;
        _version += 1;
        final nextPosition = SourcePosition(
          epoch: _epoch,
          version: SourceVersion(_version),
        );
        final group = ConsistencyGroup(
          id: ConsistencyGroupId(
            '${fieldGroup.resource.stableKey}-${nextPosition.version.value}',
            source: SourceIdentity(
              scope: fieldGroup.resource.scope,
              stableKey: fieldGroup.resource.stableKey,
            ),
          ),
          position: nextPosition,
          changed: <ChangedFieldGroup>[ChangedFieldGroup.of(fieldGroup)],
        );
        final snapshot = ResourceSnapshot<T>(
          fieldGroup: fieldGroup,
          epoch: nextPosition.epoch,
          version: nextPosition.version,
          value: update.value,
          consistencyGroup: group,
        );
        changes.add(
          SourceChange<T>(
            snapshot: snapshot,
            base: installed,
            group: group,
            trace: update.trace,
          ),
        );
        installed = nextPosition;
      },
      onDone: () {
        if (!changes.isClosed) unawaited(changes.close());
      },
    );
    changes.onCancel = () async {
      await subscription.cancel();
    };
    return SourceObservation<T>(
      initial: ResourceSnapshot<T>(
        fieldGroup: fieldGroup,
        epoch: position.epoch,
        version: position.version,
        value: _source.current,
      ),
      changes: changes.stream,
    );
  }
}

/// Stable resource identity for the autostart region.
final settingsAutostartFieldGroup =
    ResourceFieldGroup<SettingsAutostartProjection>(
      resource: ResourceKey(
        scope: const ResourceScope('settings'),
        stableKey: 'autostart',
      ),
      name: 'inputs',
    );

/// Stable resource identity for the resource-usage region.
final settingsResourceUsageFieldGroup =
    ResourceFieldGroup<SettingsResourceUsageProjection>(
      resource: ResourceKey(
        scope: const ResourceScope('settings'),
        stableKey: 'resource-usage',
      ),
      name: 'inputs',
    );

int _sharedEpochCounter = 0;

/// Creates the autostart presentation source over the existing autostart
/// application source.
SettingsValuePresentationSource<SettingsAutostartProjection>
settingsAutostartPresentationSource(
  ProjectionSource<SettingsAutostartProjection> source,
) {
  return SettingsValuePresentationSource<SettingsAutostartProjection>(
    fieldGroup: settingsAutostartFieldGroup,
    source: source,
    epochId: 'settings-autostart-${_sharedEpochCounter++}',
  );
}

/// Creates the resource-usage presentation source over the existing
/// resource-usage application source.
SettingsValuePresentationSource<SettingsResourceUsageProjection>
settingsResourceUsagePresentationSource(
  ProjectionSource<SettingsResourceUsageProjection> source,
) {
  return SettingsValuePresentationSource<SettingsResourceUsageProjection>(
    fieldGroup: settingsResourceUsageFieldGroup,
    source: source,
    epochId: 'settings-resource-usage-${_sharedEpochCounter++}',
  );
}
