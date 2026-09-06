import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/contracts/appearance/appearance_preset_config.dart';
import 'package:licoup/src/contracts/client_update_models.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';
import 'package:licoup/src/presentation/settings/settings_binding.dart';
import 'package:licoup/src/presentation/settings/settings_effect.dart';
import 'package:licoup/src/presentation/settings/settings_intent.dart';
import 'package:licoup/src/presentation/settings/settings_projection.dart';

final class SettingsProjectionFixture
    implements ProjectionSource<SettingsProjection> {
  SettingsProjectionFixture(this._current);

  final StreamController<ProjectionUpdate<SettingsProjection>> _changes =
      StreamController<ProjectionUpdate<SettingsProjection>>.broadcast(
        sync: true,
      );
  SettingsProjection _current;

  @override
  SettingsProjection get current => _current;

  @override
  Stream<ProjectionUpdate<SettingsProjection>> get changes => _changes.stream;

  void publish(SettingsProjection value, {TraceContext? trace}) {
    _current = value;
    _changes.add(ProjectionUpdate(value, trace: trace));
  }

  Future<void> dispose() => _changes.close();
}

final class SettingsValueProjectionFixture<T> implements ProjectionSource<T> {
  SettingsValueProjectionFixture(this._current);

  final StreamController<ProjectionUpdate<T>> _changes =
      StreamController<ProjectionUpdate<T>>.broadcast(sync: true);
  T _current;

  @override
  T get current => _current;

  @override
  Stream<ProjectionUpdate<T>> get changes => _changes.stream;

  void publish(T value, {TraceContext? trace}) {
    _current = value;
    _changes.add(ProjectionUpdate(value, trace: trace));
  }

  Future<void> dispose() => _changes.close();
}

final class RecordingSettingsIntents implements IntentSink<SettingsIntent> {
  RecordingSettingsIntents({this.onSend});

  final void Function(SettingsIntent intent)? onSend;
  final List<SettingsIntent> values = [];

  @override
  void send(SettingsIntent intent) {
    values.add(intent);
    onSend?.call(intent);
  }
}

final class RecordingSettingsEffects implements EffectSource<SettingsEffect> {
  final StreamController<SettingsEffect> _effects =
      StreamController<SettingsEffect>.broadcast(sync: true);

  @override
  Stream<SettingsEffect> get effects => _effects.stream;

  void emit(SettingsEffect effect) => _effects.add(effect);

  Future<void> dispose() => _effects.close();
}

SettingsProjection settingsProjectionFixture({
  String appearanceId = AppearancePresetIds.licoSoda,
  String locale = 'system',
  String layoutId = 'dashboard',
  List<PresentationChoice>? layoutChoices,
  List<ArchivedConversationProjection> archived = const [],
  PresentationPhase layoutPhase = PresentationPhase.ready,
  String layoutFailureReasonCode = '',
  String appearancePresetDirectoryPath = 'test-data/appearance',
  int appearancePresetLoadErrorCount = 0,
  String portableDataPath = 'test-data/licoup',
  String snapshotRootPath = 'test-data/licoup/backups',
  bool savingSnapshotRoot = false,
  String clientLogExportPath = '',
  bool exportingClientLogs = false,
  ClientUpdateStatus clientUpdateStatus = const ClientUpdateStatus(
    phase: ClientUpdatePhase.idle,
    runningVersion: '0.1.1',
    runningReleaseTrack: ReleaseTrack.nightly,
    targetReleaseTrack: ReleaseTrack.nightly,
  ),
  String clientUpdateRepo = kClientUpdateGithubRepo,
  SettingsCatalogProjection catalog = const SettingsCatalogProjection(
    phase: SettingsCatalogPhase.idle,
    reasonCode: 'catalog_current',
    busy: false,
    partitionCount: 0,
    pendingInvalidationCount: 0,
    appliedCohortCount: 0,
    uiObservedRevision: -1,
  ),
  PresentationPhase phase = PresentationPhase.ready,
  PresentationNotice? notice,
}) => SettingsProjection(
  appearancePresetId: appearanceId,
  appearancePresets: [
    for (final preset in builtInAppearancePresetConfigs)
      SettingsAppearancePresetProjection(
        id: preset.id,
        englishLabel: preset.labelFor(),
        chineseLabel: preset.labelFor('zh-CN'),
        mode: switch (preset.mode) {
          AppearancePresetMode.system => SettingsAppearanceMode.system,
          AppearancePresetMode.light => SettingsAppearanceMode.light,
          AppearancePresetMode.dark => SettingsAppearanceMode.dark,
        },
        lightPresetId: preset.lightPresetId ?? '',
        darkPresetId: preset.darkPresetId ?? '',
      ),
  ],
  localeChoices: [
    for (final value in const ['system', 'zh', 'en'])
      PresentationChoice(id: value, label: value, selected: value == locale),
  ],
  layoutChoices:
      layoutChoices ??
      [
        PresentationChoice(
          id: 'dashboard',
          label: 'Dashboard',
          selected: layoutId == 'dashboard',
          enabled: false,
        ),
        PresentationChoice(
          id: 'atlas',
          label: 'Atlas',
          selected: layoutId == 'atlas',
        ),
      ],
  archivedConversations: archived,
  layoutPhase: layoutPhase,
  layoutFailureReasonCode: layoutFailureReasonCode,
  appearancePresetDirectoryPath: appearancePresetDirectoryPath,
  appearancePresetLoadErrorCount: appearancePresetLoadErrorCount,
  portableDataPath: portableDataPath,
  snapshotRootPath: snapshotRootPath,
  savingSnapshotRoot: savingSnapshotRoot,
  clientLogExportPath: clientLogExportPath,
  exportingClientLogs: exportingClientLogs,
  clientUpdate: SettingsClientUpdateProjection(
    phase: clientUpdateStatus.phase,
    runningVersion: clientUpdateStatus.runningVersion,
    runningReleaseTrack: clientUpdateStatus.runningReleaseTrack,
    targetReleaseTrack: clientUpdateStatus.targetReleaseTrack,
    availableVersion: clientUpdateStatus.availableVersion,
    githubReleaseUrl: clientUpdateStatus.githubReleaseUrl,
    artifactSha256: clientUpdateStatus.artifactSha256,
    updateAvailable: clientUpdateStatus.updateAvailable,
  ),
  clientUpdateRepo: clientUpdateRepo,
  catalog: catalog,
  phase: phase,
  notice: notice,
);

SettingsBinding settingsBindingFixture({
  SettingsProjectionFixture? source,
  SettingsValueProjectionFixture<SettingsResourceUsageProjection>?
  resourceUsage,
  SettingsValueProjectionFixture<SettingsAutostartProjection>? autostart,
  RecordingSettingsIntents? intents,
  RecordingSettingsEffects? effects,
}) => SettingsBinding(
  projection: source ?? SettingsProjectionFixture(settingsProjectionFixture()),
  resourceUsage:
      resourceUsage ??
      SettingsValueProjectionFixture(
        SettingsResourceUsageProjection.unsupported(),
      ),
  autostart:
      autostart ??
      SettingsValueProjectionFixture(
        const SettingsAutostartProjection.loading(),
      ),
  intents: intents ?? RecordingSettingsIntents(),
  effects: effects ?? RecordingSettingsEffects(),
);
