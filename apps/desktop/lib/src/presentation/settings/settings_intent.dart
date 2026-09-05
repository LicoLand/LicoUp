import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/contracts/client_update_models.dart';

sealed class SettingsIntent {
  const SettingsIntent({this.trace});

  final TraceContext? trace;
}

final class SetAppearancePreference extends SettingsIntent {
  const SetAppearancePreference(this.presetId, {super.trace});
  final String presetId;
}

final class SetLocalePreference extends SettingsIntent {
  const SetLocalePreference(this.preference, {super.trace});
  final String preference;
}

final class SetLayoutPreference extends SettingsIntent {
  const SetLayoutPreference(this.profileId, {super.trace});
  final String profileId;
}

final class CheckForClientUpdate extends SettingsIntent {
  const CheckForClientUpdate({super.trace});
}

final class DownloadClientUpdate extends SettingsIntent {
  const DownloadClientUpdate({super.trace});
}

final class ApplyClientUpdate extends SettingsIntent {
  const ApplyClientUpdate({super.trace});
}

final class HydrateClientUpdateIdentity extends SettingsIntent {
  const HydrateClientUpdateIdentity({super.trace});
}

final class SetClientUpdateReleaseTrack extends SettingsIntent {
  const SetClientUpdateReleaseTrack(this.track, {super.trace});
  final ReleaseTrack track;
}

final class ExportClientDiagnostics extends SettingsIntent {
  const ExportClientDiagnostics(this.destinationPath, {super.trace});
  final String destinationPath;
}

enum SettingsDirectory {
  appearancePresets,
  portableData,
  conversationSnapshots,
  clientLogs,
}

final class OpenSettingsDirectory extends SettingsIntent {
  const OpenSettingsDirectory(
    this.directory, {
    this.path,
    this.caption = '',
    super.trace,
  });
  final SettingsDirectory directory;
  final String? path;
  final String caption;
}

final class ReloadAppearancePresets extends SettingsIntent {
  const ReloadAppearancePresets({super.trace});
}

final class RefreshConversationSnapshotLocation extends SettingsIntent {
  const RefreshConversationSnapshotLocation({super.trace});
}

final class SetConversationSnapshotLocation extends SettingsIntent {
  const SetConversationSnapshotLocation(this.path, {super.trace});
  final String path;
}

final class RefreshArchivedConversations extends SettingsIntent {
  const RefreshArchivedConversations({super.trace});
}

final class RestoreArchivedConversation extends SettingsIntent {
  const RestoreArchivedConversation(this.conversationId, {super.trace});
  final String conversationId;
}

final class RefreshCatalogStatus extends SettingsIntent {
  const RefreshCatalogStatus({super.trace});
}

final class StartSettingsResourceUsage extends SettingsIntent {
  const StartSettingsResourceUsage({super.trace});
}

final class StopSettingsResourceUsage extends SettingsIntent {
  const StopSettingsResourceUsage({super.trace});
}

final class RefreshSettingsAutostart extends SettingsIntent {
  const RefreshSettingsAutostart({super.trace});
}

enum SettingsAutostartComponent { desktop, gateway, mcp }

final class SetSettingsAutostart extends SettingsIntent {
  const SetSettingsAutostart({
    required this.component,
    required this.enabled,
    this.silent,
    super.trace,
  });
  final SettingsAutostartComponent component;
  final bool enabled;
  final bool? silent;
}
