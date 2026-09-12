import 'package:licoup/src/presentation/presentation_semantics.dart';
import 'package:licoup/src/presentation/settings/settings_projection.dart';

/// Values consumed by the appearance controls. Layout and background settings
/// can update independently without rebuilding the theme catalog.
final class AppearanceSettingsSelection {
  AppearanceSettingsSelection.from(SettingsProjection value)
    : appearancePresetId = value.appearancePresetId,
      appearancePresets = value.appearancePresets,
      appearancePresetDirectoryPath = value.appearancePresetDirectoryPath,
      appearancePresetLoadErrorCount = value.appearancePresetLoadErrorCount,
      reduceMotion = value.reduceMotion;

  final String appearancePresetId;
  final List<SettingsAppearancePresetProjection> appearancePresets;
  final String appearancePresetDirectoryPath;
  final int appearancePresetLoadErrorCount;
  final bool reduceMotion;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AppearanceSettingsSelection &&
          other.appearancePresetId == appearancePresetId &&
          samePresentationList(other.appearancePresets, appearancePresets) &&
          other.appearancePresetDirectoryPath ==
              appearancePresetDirectoryPath &&
          other.appearancePresetLoadErrorCount ==
              appearancePresetLoadErrorCount &&
          other.reduceMotion == reduceMotion;

  @override
  int get hashCode => Object.hash(
    appearancePresetId,
    Object.hashAll(appearancePresets),
    appearancePresetDirectoryPath,
    appearancePresetLoadErrorCount,
    reduceMotion,
  );
}

typedef StorageSettingsSelection = ({
  String portableDataPath,
  String snapshotRootPath,
  bool savingSnapshotRoot,
});

StorageSettingsSelection selectStorageSettings(SettingsProjection value) => (
  portableDataPath: value.portableDataPath,
  snapshotRootPath: value.snapshotRootPath,
  savingSnapshotRoot: value.savingSnapshotRoot,
);

final class LayoutSettingsSelection {
  LayoutSettingsSelection.from(SettingsProjection value)
    : layoutChoices = value.layoutChoices,
      layoutPhase = value.layoutPhase,
      layoutFailureReasonCode = value.layoutFailureReasonCode;

  final List<PresentationChoice> layoutChoices;
  final PresentationPhase layoutPhase;
  final String layoutFailureReasonCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LayoutSettingsSelection &&
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

final class ArchivedSettingsSelection {
  ArchivedSettingsSelection.from(SettingsProjection value)
    : archivedConversations = value.archivedConversations,
      loading = value.archivedConversationsLoading,
      notice = value.notice?.id.startsWith('settings-conversation-') == true
          ? value.notice
          : null;

  final List<ArchivedConversationProjection> archivedConversations;
  final bool loading;
  final PresentationNotice? notice;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ArchivedSettingsSelection &&
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
