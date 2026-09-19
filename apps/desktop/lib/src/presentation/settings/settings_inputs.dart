import 'package:licoup/src/presentation/presentation_semantics.dart';
import 'package:licoup/src/presentation/settings/settings_projection.dart';

/// Narrow immutable Inputs consumed by the general settings region. Locale
/// updates install without rebuilding appearance, layout, or storage regions.
final class SettingsGeneralInputs {
  SettingsGeneralInputs({required Iterable<PresentationChoice> localeChoices})
    : localeChoices = immutablePresentationList(localeChoices);

  final List<PresentationChoice> localeChoices;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SettingsGeneralInputs &&
          samePresentationList(other.localeChoices, localeChoices);

  @override
  int get hashCode => Object.hashAll(localeChoices);
}

/// Values consumed by the appearance controls. Layout and background settings
/// can update independently without rebuilding the theme catalog.
final class SettingsAppearanceInputs {
  SettingsAppearanceInputs({
    required this.appearancePresetId,
    required Iterable<SettingsAppearancePresetProjection> appearancePresets,
    required this.appearancePresetDirectoryPath,
    required this.appearancePresetLoadErrorCount,
    required this.reduceMotion,
    required this.loadingEffectId,
  }) : appearancePresets = immutablePresentationList(appearancePresets);

  final String appearancePresetId;
  final List<SettingsAppearancePresetProjection> appearancePresets;
  final String appearancePresetDirectoryPath;
  final int appearancePresetLoadErrorCount;
  final bool reduceMotion;
  final String loadingEffectId;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SettingsAppearanceInputs &&
          other.appearancePresetId == appearancePresetId &&
          samePresentationList(other.appearancePresets, appearancePresets) &&
          other.appearancePresetDirectoryPath ==
              appearancePresetDirectoryPath &&
          other.appearancePresetLoadErrorCount ==
              appearancePresetLoadErrorCount &&
          other.reduceMotion == reduceMotion &&
          other.loadingEffectId == loadingEffectId;

  @override
  int get hashCode => Object.hash(
    appearancePresetId,
    Object.hashAll(appearancePresets),
    appearancePresetDirectoryPath,
    appearancePresetLoadErrorCount,
    reduceMotion,
    loadingEffectId,
  );
}

/// Values consumed by the layout profile selector.
final class SettingsLayoutInputs {
  SettingsLayoutInputs({
    required Iterable<PresentationChoice> layoutChoices,
    required this.layoutPhase,
    required this.layoutFailureReasonCode,
  }) : layoutChoices = immutablePresentationList(layoutChoices);

  final List<PresentationChoice> layoutChoices;
  final PresentationPhase layoutPhase;
  final String layoutFailureReasonCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SettingsLayoutInputs &&
          samePresentationList(other.layoutChoices, layoutChoices) &&
          other.layoutPhase == layoutPhase &&
          other.layoutFailureReasonCode == layoutFailureReasonCode;

  @override
  int get hashCode => Object.hash(
    Object.hashAll(layoutChoices),
    layoutPhase,
    layoutFailureReasonCode,
  );
}

/// Values consumed by the storage settings region.
final class SettingsStorageInputs {
  const SettingsStorageInputs({
    required this.portableDataPath,
    required this.snapshotRootPath,
    required this.savingSnapshotRoot,
  });

  final String portableDataPath;
  final String snapshotRootPath;
  final bool savingSnapshotRoot;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SettingsStorageInputs &&
          other.portableDataPath == portableDataPath &&
          other.snapshotRootPath == snapshotRootPath &&
          other.savingSnapshotRoot == savingSnapshotRoot;

  @override
  int get hashCode =>
      Object.hash(portableDataPath, snapshotRootPath, savingSnapshotRoot);
}

/// Values consumed by the client update card.
final class SettingsUpdateInputs {
  const SettingsUpdateInputs({required this.status, required this.repository});

  final SettingsClientUpdateProjection status;
  final String repository;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SettingsUpdateInputs &&
          other.status == status &&
          other.repository == repository;

  @override
  int get hashCode => Object.hash(status, repository);
}

/// Values consumed by the archived conversations settings section.
final class SettingsArchivedInputs {
  SettingsArchivedInputs({
    required Iterable<ArchivedConversationProjection> archivedConversations,
    required this.loading,
    required this.notice,
  }) : archivedConversations = immutablePresentationList(archivedConversations);

  final List<ArchivedConversationProjection> archivedConversations;
  final bool loading;
  final PresentationNotice? notice;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SettingsArchivedInputs &&
          samePresentationList(
            other.archivedConversations,
            archivedConversations,
          ) &&
          other.loading == loading &&
          other.notice == notice;

  @override
  int get hashCode =>
      Object.hash(Object.hashAll(archivedConversations), loading, notice);
}

/// Values consumed by the client log export row.
final class SettingsLogExportInputs {
  const SettingsLogExportInputs({required this.path, required this.busy});

  final String path;
  final bool busy;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SettingsLogExportInputs &&
          other.path == path &&
          other.busy == busy;

  @override
  int get hashCode => Object.hash(path, busy);
}
