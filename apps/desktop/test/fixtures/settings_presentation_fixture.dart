import 'package:presentation_contract/presentation_contract.dart';
import 'package:riverpod/misc.dart' show Override;

import 'package:licoup/src/presentation/settings/settings_inputs.dart';
import 'package:licoup/src/presentation/settings/settings_projection.dart';
import 'package:licoup/src/presentation/settings/settings_providers.dart';

import 'presentation_source_fixture.dart';
import 'settings_binding_fixture.dart';

/// Synthetic settings presentation sources wired as provider overrides for
/// feature widget tests. Region values derive from the existing projection
/// fixture shape so test data setup stays unchanged.
final class SettingsPresentationFixture {
  factory SettingsPresentationFixture({SettingsProjection? projection}) {
    return SettingsPresentationFixture._(
      projection ?? settingsProjectionFixture(),
    );
  }

  SettingsPresentationFixture._(SettingsProjection projection)
    : general = PresentationSourceFixture(
        fieldGroup: _fieldGroup('general'),
        initial: _generalOf(projection),
      ),
      appearance = PresentationSourceFixture(
        fieldGroup: _fieldGroup('appearance'),
        initial: _appearanceOf(projection),
      ),
      layout = PresentationSourceFixture(
        fieldGroup: _fieldGroup('layout'),
        initial: _layoutOf(projection),
      ),
      storage = PresentationSourceFixture(
        fieldGroup: _fieldGroup('storage'),
        initial: _storageOf(projection),
      ),
      update = PresentationSourceFixture(
        fieldGroup: _fieldGroup('update'),
        initial: _updateOf(projection),
      ),
      archived = PresentationSourceFixture(
        fieldGroup: _fieldGroup('archived'),
        initial: _archivedOf(projection),
      ),
      logExport = PresentationSourceFixture(
        fieldGroup: _fieldGroup('log-export'),
        initial: _logExportOf(projection),
      ),
      autostart = PresentationSourceFixture(
        fieldGroup: _fieldGroup('autostart'),
        initial: const SettingsAutostartProjection.loading(),
      ),
      resourceUsage = PresentationSourceFixture(
        fieldGroup: _fieldGroup('resource-usage'),
        initial: SettingsResourceUsageProjection.unsupported(),
      );

  final PresentationSourceFixture<SettingsGeneralInputs> general;
  final PresentationSourceFixture<SettingsAppearanceInputs> appearance;
  final PresentationSourceFixture<SettingsLayoutInputs> layout;
  final PresentationSourceFixture<SettingsStorageInputs> storage;
  final PresentationSourceFixture<SettingsUpdateInputs> update;
  final PresentationSourceFixture<SettingsArchivedInputs> archived;
  final PresentationSourceFixture<SettingsLogExportInputs> logExport;
  final PresentationSourceFixture<SettingsAutostartProjection> autostart;
  final PresentationSourceFixture<SettingsResourceUsageProjection>
  resourceUsage;

  List<Override> get overrides => <Override>[
    settingsGeneralSourceProvider.overrideWithValue(general),
    settingsAppearanceSourceProvider.overrideWithValue(appearance),
    settingsLayoutSourceProvider.overrideWithValue(layout),
    settingsStorageSourceProvider.overrideWithValue(storage),
    settingsUpdateSourceProvider.overrideWithValue(update),
    settingsArchivedSourceProvider.overrideWithValue(archived),
    settingsLogExportSourceProvider.overrideWithValue(logExport),
    settingsAutostartSourceProvider.overrideWithValue(autostart),
    settingsResourceUsageSourceProvider.overrideWithValue(resourceUsage),
  ];

  /// Republishes the regions derived from one projection fixture value.
  ///
  /// Mirrors the production hub: a region whose value is unchanged keeps its
  /// installed snapshot, so subscribers of unrelated regions do not rebuild.
  void publishProjection(SettingsProjection projection) {
    _publishIfChanged(general, _generalOf(projection));
    _publishIfChanged(appearance, _appearanceOf(projection));
    _publishIfChanged(layout, _layoutOf(projection));
    _publishIfChanged(storage, _storageOf(projection));
    _publishIfChanged(update, _updateOf(projection));
    _publishIfChanged(archived, _archivedOf(projection));
    _publishIfChanged(logExport, _logExportOf(projection));
  }

  static void _publishIfChanged<T>(
    PresentationSourceFixture<T> region,
    T next,
  ) {
    if (region.value == next) return;
    region.publish(next);
  }

  Future<void> dispose() async {
    await general.dispose();
    await appearance.dispose();
    await layout.dispose();
    await storage.dispose();
    await update.dispose();
    await archived.dispose();
    await logExport.dispose();
    await autostart.dispose();
    await resourceUsage.dispose();
  }

  static ResourceFieldGroup<T> _fieldGroup<T>(String stableKey) =>
      ResourceFieldGroup<T>(
        resource: ResourceKey(
          scope: const ResourceScope('settings'),
          stableKey: stableKey,
        ),
        name: 'inputs',
      );

  static SettingsGeneralInputs _generalOf(SettingsProjection projection) =>
      SettingsGeneralInputs(localeChoices: projection.localeChoices);

  static SettingsAppearanceInputs _appearanceOf(
    SettingsProjection projection,
  ) => SettingsAppearanceInputs(
    appearancePresetId: projection.appearancePresetId,
    appearancePresets: projection.appearancePresets,
    appearancePresetDirectoryPath: projection.appearancePresetDirectoryPath,
    appearancePresetLoadErrorCount: projection.appearancePresetLoadErrorCount,
    reduceMotion: projection.reduceMotion,
    loadingEffectId: projection.loadingEffectId,
  );

  static SettingsLayoutInputs _layoutOf(SettingsProjection projection) =>
      SettingsLayoutInputs(
        layoutChoices: projection.layoutChoices,
        layoutPhase: projection.layoutPhase,
        layoutFailureReasonCode: projection.layoutFailureReasonCode,
      );

  static SettingsStorageInputs _storageOf(SettingsProjection projection) =>
      SettingsStorageInputs(
        portableDataPath: projection.portableDataPath,
        snapshotRootPath: projection.snapshotRootPath,
        savingSnapshotRoot: projection.savingSnapshotRoot,
      );

  static SettingsUpdateInputs _updateOf(SettingsProjection projection) =>
      SettingsUpdateInputs(
        status: projection.clientUpdate,
        repository: projection.clientUpdateRepo,
      );

  static SettingsArchivedInputs _archivedOf(SettingsProjection projection) =>
      SettingsArchivedInputs(
        archivedConversations: projection.archivedConversations,
        loading: projection.archivedConversationsLoading,
        notice:
            projection.notice?.id.startsWith('settings-conversation-') == true
            ? projection.notice
            : null,
      );

  static SettingsLogExportInputs _logExportOf(SettingsProjection projection) =>
      SettingsLogExportInputs(
        path: projection.clientLogExportPath,
        busy: projection.exportingClientLogs,
      );
}
