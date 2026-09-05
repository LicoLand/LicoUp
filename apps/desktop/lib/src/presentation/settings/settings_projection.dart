import 'package:licoup/src/contracts/client_update_models.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';

enum SettingsAppearanceMode { system, light, dark }

final class SettingsAppearancePresetProjection {
  const SettingsAppearancePresetProjection({
    required this.id,
    required this.englishLabel,
    required this.chineseLabel,
    required this.mode,
    this.lightPresetId = '',
    this.darkPresetId = '',
  });

  final String id;
  final String englishLabel;
  final String chineseLabel;
  final SettingsAppearanceMode mode;
  final String lightPresetId;
  final String darkPresetId;

  String labelFor(bool chinese) => chinese ? chineseLabel : englishLabel;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SettingsAppearancePresetProjection &&
          other.id == id &&
          other.englishLabel == englishLabel &&
          other.chineseLabel == chineseLabel &&
          other.mode == mode &&
          other.lightPresetId == lightPresetId &&
          other.darkPresetId == darkPresetId;

  @override
  int get hashCode => Object.hash(
    id,
    englishLabel,
    chineseLabel,
    mode,
    lightPresetId,
    darkPresetId,
  );
}

enum SettingsCatalogPhase {
  disabled,
  idle,
  reconciling,
  ready,
  blocked,
  failed,
}

final class SettingsCatalogProjection {
  const SettingsCatalogProjection({
    required this.phase,
    required this.reasonCode,
    required this.busy,
    required this.partitionCount,
    required this.pendingInvalidationCount,
    required this.appliedCohortCount,
    required this.uiObservedRevision,
  });

  final SettingsCatalogPhase phase;
  final String reasonCode;
  final bool busy;
  final int partitionCount;
  final int pendingInvalidationCount;
  final int appliedCohortCount;
  final int uiObservedRevision;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SettingsCatalogProjection &&
          other.phase == phase &&
          other.reasonCode == reasonCode &&
          other.busy == busy &&
          other.partitionCount == partitionCount &&
          other.pendingInvalidationCount == pendingInvalidationCount &&
          other.appliedCohortCount == appliedCohortCount &&
          other.uiObservedRevision == uiObservedRevision;

  @override
  int get hashCode => Object.hash(
    phase,
    reasonCode,
    busy,
    partitionCount,
    pendingInvalidationCount,
    appliedCohortCount,
    uiObservedRevision,
  );
}

final class SettingsClientUpdateProjection {
  const SettingsClientUpdateProjection({
    required this.phase,
    required this.runningVersion,
    required this.runningReleaseTrack,
    required this.targetReleaseTrack,
    required this.availableVersion,
    required this.githubReleaseUrl,
    required this.artifactSha256,
    required this.updateAvailable,
  });

  final ClientUpdatePhase phase;
  final String runningVersion;
  final ReleaseTrack runningReleaseTrack;
  final ReleaseTrack targetReleaseTrack;
  final String availableVersion;
  final String githubReleaseUrl;
  final String artifactSha256;
  final bool updateAvailable;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SettingsClientUpdateProjection &&
          other.phase == phase &&
          other.runningVersion == runningVersion &&
          other.runningReleaseTrack == runningReleaseTrack &&
          other.targetReleaseTrack == targetReleaseTrack &&
          other.availableVersion == availableVersion &&
          other.githubReleaseUrl == githubReleaseUrl &&
          other.artifactSha256 == artifactSha256 &&
          other.updateAvailable == updateAvailable;

  @override
  int get hashCode => Object.hash(
    phase,
    runningVersion,
    runningReleaseTrack,
    targetReleaseTrack,
    availableVersion,
    githubReleaseUrl,
    artifactSha256,
    updateAvailable,
  );
}

final class ArchivedConversationProjection {
  const ArchivedConversationProjection({
    required this.id,
    required this.title,
    required this.isGroup,
    required this.membershipCount,
    required this.updatedAtUnixMs,
  });

  final String id;
  final String title;
  final bool isGroup;
  final int membershipCount;
  final int updatedAtUnixMs;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ArchivedConversationProjection &&
          other.id == id &&
          other.title == title &&
          other.isGroup == isGroup &&
          other.membershipCount == membershipCount &&
          other.updatedAtUnixMs == updatedAtUnixMs;

  @override
  int get hashCode =>
      Object.hash(id, title, isGroup, membershipCount, updatedAtUnixMs);
}

final class SettingsResourceUsageProjection {
  SettingsResourceUsageProjection({
    required this.supported,
    required this.clientRssBytes,
    required this.totalMemoryBytes,
    required Map<String, int> agentRssBytes,
  }) : agentRssBytes = Map<String, int>.unmodifiable(agentRssBytes);

  SettingsResourceUsageProjection.unsupported()
    : supported = false,
      clientRssBytes = 0,
      totalMemoryBytes = null,
      agentRssBytes = const {};

  final bool supported;
  final int clientRssBytes;
  final int? totalMemoryBytes;
  final Map<String, int> agentRssBytes;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SettingsResourceUsageProjection &&
          other.supported == supported &&
          other.clientRssBytes == clientRssBytes &&
          other.totalMemoryBytes == totalMemoryBytes &&
          _sameStringIntMap(other.agentRssBytes, agentRssBytes);

  @override
  int get hashCode => Object.hash(
    supported,
    clientRssBytes,
    totalMemoryBytes,
    Object.hashAllUnordered(
      agentRssBytes.entries.map((entry) => Object.hash(entry.key, entry.value)),
    ),
  );
}

enum SettingsAutostartPhase { loading, ready, applying, unsupported, failed }

enum SettingsAutostartResult { none, saved, loadFailed, saveFailed }

final class SettingsAutostartProjection {
  const SettingsAutostartProjection({
    required this.phase,
    required this.supported,
    required this.desktopEnabled,
    required this.desktopSilent,
    required this.gatewayEnabled,
    required this.mcpEnabled,
    this.result = SettingsAutostartResult.none,
  });

  const SettingsAutostartProjection.loading()
    : phase = SettingsAutostartPhase.loading,
      supported = false,
      desktopEnabled = false,
      desktopSilent = false,
      gatewayEnabled = false,
      mcpEnabled = false,
      result = SettingsAutostartResult.none;

  final SettingsAutostartPhase phase;
  final bool supported;
  final bool desktopEnabled;
  final bool desktopSilent;
  final bool gatewayEnabled;
  final bool mcpEnabled;
  final SettingsAutostartResult result;

  SettingsAutostartProjection copyWith({
    SettingsAutostartPhase? phase,
    bool? supported,
    bool? desktopEnabled,
    bool? desktopSilent,
    bool? gatewayEnabled,
    bool? mcpEnabled,
    SettingsAutostartResult? result,
  }) => SettingsAutostartProjection(
    phase: phase ?? this.phase,
    supported: supported ?? this.supported,
    desktopEnabled: desktopEnabled ?? this.desktopEnabled,
    desktopSilent: desktopSilent ?? this.desktopSilent,
    gatewayEnabled: gatewayEnabled ?? this.gatewayEnabled,
    mcpEnabled: mcpEnabled ?? this.mcpEnabled,
    result: result ?? this.result,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SettingsAutostartProjection &&
          other.phase == phase &&
          other.supported == supported &&
          other.desktopEnabled == desktopEnabled &&
          other.desktopSilent == desktopSilent &&
          other.gatewayEnabled == gatewayEnabled &&
          other.mcpEnabled == mcpEnabled &&
          other.result == result;

  @override
  int get hashCode => Object.hash(
    phase,
    supported,
    desktopEnabled,
    desktopSilent,
    gatewayEnabled,
    mcpEnabled,
    result,
  );
}

final class SettingsProjection {
  SettingsProjection({
    required this.appearancePresetId,
    required Iterable<SettingsAppearancePresetProjection> appearancePresets,
    required Iterable<PresentationChoice> localeChoices,
    required Iterable<PresentationChoice> layoutChoices,
    required Iterable<ArchivedConversationProjection> archivedConversations,
    required this.layoutPhase,
    required this.layoutFailureReasonCode,
    required this.appearancePresetDirectoryPath,
    required this.appearancePresetLoadErrorCount,
    required this.portableDataPath,
    required this.snapshotRootPath,
    required this.savingSnapshotRoot,
    required this.clientLogExportPath,
    required this.exportingClientLogs,
    required this.clientUpdate,
    required this.clientUpdateRepo,
    required this.catalog,
    required this.phase,
    this.notice,
  }) : appearancePresets = immutablePresentationList(appearancePresets),
       localeChoices = immutablePresentationList(localeChoices),
       layoutChoices = immutablePresentationList(layoutChoices),
       archivedConversations = immutablePresentationList(archivedConversations);

  final String appearancePresetId;
  final List<SettingsAppearancePresetProjection> appearancePresets;
  final List<PresentationChoice> localeChoices;
  final List<PresentationChoice> layoutChoices;
  final List<ArchivedConversationProjection> archivedConversations;
  final PresentationPhase layoutPhase;
  final String layoutFailureReasonCode;
  final String appearancePresetDirectoryPath;
  final int appearancePresetLoadErrorCount;
  final String portableDataPath;
  final String snapshotRootPath;
  final bool savingSnapshotRoot;
  final String clientLogExportPath;
  final bool exportingClientLogs;
  final SettingsClientUpdateProjection clientUpdate;
  final String clientUpdateRepo;
  final SettingsCatalogProjection catalog;
  final PresentationPhase phase;
  final PresentationNotice? notice;
}

bool _sameStringIntMap(Map<String, int> left, Map<String, int> right) {
  if (identical(left, right)) return true;
  if (left.length != right.length) return false;
  for (final entry in left.entries) {
    if (right[entry.key] != entry.value) return false;
  }
  return true;
}
