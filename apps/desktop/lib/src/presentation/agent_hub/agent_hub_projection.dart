import 'package:licoup/src/presentation/presentation_semantics.dart';

enum AgentHubAdaptationProjection { deep, partial, pending }

final class AgentHubChannelProjection {
  const AgentHubChannelProjection({
    required this.id,
    required this.label,
    required this.versionPolicy,
    required this.officialSource,
    required this.commandPreview,
  });

  final String id;
  final String label;
  final String versionPolicy;
  final String officialSource;
  final String commandPreview;

  String get chipLabel => label;

  Uri? get httpsSource {
    final uri = Uri.tryParse(officialSource.trim());
    return uri != null &&
            uri.scheme.toLowerCase() == 'https' &&
            uri.host.isNotEmpty
        ? uri
        : null;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AgentHubChannelProjection &&
          other.id == id &&
          other.label == label &&
          other.versionPolicy == versionPolicy &&
          other.officialSource == officialSource &&
          other.commandPreview == commandPreview;

  @override
  int get hashCode =>
      Object.hash(id, label, versionPolicy, officialSource, commandPreview);
}

final class AgentHubEntryProjection {
  AgentHubEntryProjection({
    required this.id,
    required this.name,
    required this.description,
    required this.adaptation,
    required this.installed,
    required this.owned,
    required this.installable,
    required this.busy,
    required this.primaryAction,
    required this.actionStateLabel,
    required this.versionLabel,
    required this.updateAvailable,
    required this.homepage,
    required this.channelLabel,
    required Iterable<AgentHubChannelProjection> channels,
  }) : channels = immutablePresentationList(channels);

  final String id;
  final String name;
  final String description;
  final AgentHubAdaptationProjection adaptation;
  final bool installed;
  final bool owned;
  final bool installable;
  final bool busy;
  final String primaryAction;
  final String actionStateLabel;
  final String versionLabel;
  final bool updateAvailable;
  final String homepage;
  final String channelLabel;
  final List<AgentHubChannelProjection> channels;

  String get displayName => name;
  String get summary => description;
  bool get present => installed;
  bool get showsManageActions => installed;
  List<AgentHubChannelProjection> get pickerChannels => channels;

  Uri? get officialHomepage {
    final uri = Uri.tryParse(homepage.trim());
    return uri != null &&
            uri.scheme.toLowerCase() == 'https' &&
            uri.host.isNotEmpty
        ? uri
        : null;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AgentHubEntryProjection &&
          other.id == id &&
          other.name == name &&
          other.description == description &&
          other.adaptation == adaptation &&
          other.installed == installed &&
          other.owned == owned &&
          other.installable == installable &&
          other.busy == busy &&
          other.primaryAction == primaryAction &&
          other.actionStateLabel == actionStateLabel &&
          other.versionLabel == versionLabel &&
          other.updateAvailable == updateAvailable &&
          other.homepage == homepage &&
          other.channelLabel == channelLabel &&
          samePresentationList(other.channels, channels);

  @override
  int get hashCode => Object.hash(
    id,
    name,
    description,
    adaptation,
    installed,
    owned,
    installable,
    busy,
    primaryAction,
    actionStateLabel,
    versionLabel,
    updateAvailable,
    homepage,
    channelLabel,
    Object.hashAll(channels),
  );
}

final class AgentHubProjection {
  AgentHubProjection({
    required Iterable<AgentHubEntryProjection> entries,
    required this.phase,
    this.refreshRevision = 0,
    this.notice,
  }) : entries = immutablePresentationList(entries);

  final List<AgentHubEntryProjection> entries;
  final PresentationPhase phase;
  final int refreshRevision;
  final PresentationNotice? notice;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AgentHubProjection &&
          samePresentationList(other.entries, entries) &&
          other.phase == phase &&
          other.refreshRevision == refreshRevision &&
          other.notice == notice;

  @override
  int get hashCode =>
      Object.hash(Object.hashAll(entries), phase, refreshRevision, notice);
}
