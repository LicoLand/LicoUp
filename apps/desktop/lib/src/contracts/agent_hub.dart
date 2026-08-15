/// Ordinary Agent Hub lifecycle. Protected-comms is outside this port.
enum AgentHubLifecycleAction {
  plan,
  confirm,
  install,
  update,
  uninstall,
  verify,
  rescan,
}

/// Client runtimes that expose the ordinary Hub capability matrix.
enum AgentHubRuntimePlatform { macos, windows, linux, android, ios }

enum AgentHubAdaptationDepth { deep, partial }

enum AgentHubOperationStatus {
  completed,
  nativeNotWired,
  unsupported,
  failed,
  cancelled,
  externalProtected,
}

/// One Hub card projected from the native recipe catalog + discovery snapshot.
final class AgentHubRecipe {
  const AgentHubRecipe({
    required this.id,
    required this.displayName,
    required this.adaptation,
    this.present = false,
    this.ownership = 'none',
    this.lifecycle = 'absent',
    this.primaryAction = 'install',
    this.installable = false,
    this.selectedChannelKind = '',
    this.channelKind = '',
    this.summary = '',
    this.homepage = '',
    this.installedVersion = '',
    this.latestVersion = '',
    this.updateAvailable = false,
    this.version = '',
    this.installChannels = const [],
  });

  final String id;
  final String displayName;
  final AgentHubAdaptationDepth adaptation;
  final bool present;
  final String ownership;
  final String lifecycle;
  final String primaryAction;
  final bool installable;
  final String selectedChannelKind;
  final String channelKind;
  final String summary;
  final String homepage;
  final String installedVersion;
  final String latestVersion;
  final bool updateAvailable;
  final String version;
  final List<AgentHubInstallChannel> installChannels;

  /// Package-manager chip: planned/detected kind, else recipe preferred.
  String get channelChipLabel {
    final kind = channelKind.trim().isEmpty
        ? selectedChannelKind.trim()
        : channelKind.trim();
    return switch (kind) {
      'npm' => 'npm',
      'homebrew' => 'brew',
      'winget' => 'winget',
      'official-artifact' => 'official',
      '' => '',
      _ => kind,
    };
  }

  /// Concrete installed version from native. Empty when the agent is not
  /// installed or the probe could not parse a version — never `latest`
  /// or a localized "unknown".
  String get versionLabel {
    final raw = installedVersion.trim();
    if (raw.isEmpty) {
      return '';
    }
    final lower = raw.toLowerCase();
    if (lower == 'latest' ||
        lower == 'latest-stable' ||
        lower == 'vendor-latest') {
      return '';
    }
    return raw;
  }

  List<AgentHubInstallChannel> get pickerChannels {
    if (installChannels.isNotEmpty) {
      return installChannels;
    }
    final kind = selectedChannelKind.trim().isEmpty
        ? channelKind.trim()
        : selectedChannelKind.trim();
    if (kind.isEmpty) {
      return const [];
    }
    return [AgentHubInstallChannel(id: kind, kind: kind)];
  }

  bool get isOwned => ownership == 'owned';

  bool get isExternal =>
      ownership == 'external' || ownership == 'external_protected';

  /// Footer 更新/卸载 follow presence, not LicoUp ownership. Discovered
  /// brew/npm installs are `external` until Hub owns them; the card still
  /// shows manage actions so the corner is never blank for a present agent.
  bool get showsManageActions => present;

  Uri? get officialHomepage {
    final uri = Uri.tryParse(homepage.trim());
    if (uri == null ||
        uri.scheme.toLowerCase() != 'https' ||
        uri.host.isEmpty) {
      return null;
    }
    return uri;
  }

  factory AgentHubRecipe.fromNativeCard(Map<String, dynamic> card) {
    final id = (card['id'] as String? ?? '').trim();
    final adaptation = card['adaptation'] == 'partial'
        ? AgentHubAdaptationDepth.partial
        : AgentHubAdaptationDepth.deep;
    return AgentHubRecipe(
      id: id,
      displayName: (card['label'] as String? ?? id).trim(),
      adaptation: adaptation,
      present: card['present'] == true,
      ownership: (card['ownership'] as String? ?? 'none').trim(),
      lifecycle: (card['lifecycle'] as String? ?? 'absent').trim(),
      primaryAction: (card['primaryAction'] as String? ?? 'install').trim(),
      installable: card['installable'] == true,
      selectedChannelKind: (card['selectedChannelKind'] as String? ?? '')
          .trim(),
      channelKind: (card['channelKind'] as String? ?? '').trim(),
      summary: (card['summary'] as String? ?? '').trim(),
      homepage: (card['homepage'] as String? ?? '').trim(),
      installedVersion: (card['installedVersion'] as String? ?? '').trim(),
      latestVersion: (card['latestVersion'] as String? ?? '').trim(),
      updateAvailable: card['updateAvailable'] == true,
      version: (card['version'] as String? ?? '').trim(),
      installChannels: AgentHubInstallChannel.listFromNative(
        card['installChannels'],
      ),
    );
  }
}

final class AgentHubInstallChannel {
  const AgentHubInstallChannel({
    required this.id,
    required this.kind,
    this.versionPolicy = 'latest',
    this.officialSource = '',
    this.commandPreview = '',
  });

  final String id;
  final String kind;
  final String versionPolicy;
  final String officialSource;
  final String commandPreview;

  String get chipLabel {
    return switch (kind) {
      'npm' => 'npm',
      'homebrew' => 'brew',
      'winget' => 'winget',
      'official-artifact' => 'official',
      '' => 'official',
      _ => kind,
    };
  }

  Uri? get httpsSource {
    final uri = Uri.tryParse(officialSource.trim());
    if (uri == null ||
        uri.scheme.toLowerCase() != 'https' ||
        uri.host.isEmpty) {
      return null;
    }
    return uri;
  }

  static List<AgentHubInstallChannel> listFromNative(Object? raw) {
    if (raw is! List) {
      return const [];
    }
    return raw
        .whereType<Map>()
        .map((item) {
          final card = Map<String, dynamic>.from(item);
          return AgentHubInstallChannel(
            id: (card['id'] as String? ?? '').trim(),
            kind: (card['kind'] as String? ?? '').trim(),
            versionPolicy: (card['versionPolicy'] as String? ?? 'latest')
                .trim(),
            officialSource: (card['officialSource'] as String? ?? '').trim(),
            commandPreview: (card['commandPreview'] as String? ?? '').trim(),
          );
        })
        .where((channel) => channel.id.isNotEmpty)
        .toList();
  }
}

final class AgentHubCatalogSnapshot {
  const AgentHubCatalogSnapshot({
    required this.recipes,
    this.scanGeneration = 0,
    this.ok = true,
  });

  final List<AgentHubRecipe> recipes;
  final int scanGeneration;
  final bool ok;
}

final class AgentHubPlanRequest {
  const AgentHubPlanRequest({
    required this.recipeId,
    this.operation = 'install',
    this.channelId = '',
    this.version = 'latest',
  });

  final String recipeId;
  final String operation;
  final String channelId;
  final String version;
}

final class AgentHubConfirmRequest {
  const AgentHubConfirmRequest({required this.recipeId});

  final String recipeId;
}

final class AgentHubInstallRequest {
  const AgentHubInstallRequest({
    required this.recipeId,
    this.operation = 'install',
    this.channelId = '',
    this.version = 'latest',
    this.cancel = false,
  });

  final String recipeId;
  final String operation;
  final String channelId;
  final String version;
  final bool cancel;
}

final class AgentHubVerifyRequest {
  const AgentHubVerifyRequest({required this.recipeId});

  final String recipeId;
}

final class AgentHubRescanRequest {
  const AgentHubRescanRequest({this.recipeId = ''});

  final String recipeId;
}

final class AgentHubUpdateRequest {
  const AgentHubUpdateRequest({required this.recipeId});

  final String recipeId;
}

final class AgentHubUninstallRequest {
  const AgentHubUninstallRequest({required this.recipeId});

  final String recipeId;
}

final class AgentHubOperationResult {
  const AgentHubOperationResult({
    required this.status,
    required this.action,
    required this.recipeId,
    this.nativeStatus = '',
    this.ownership = '',
    this.events = const [],
    this.recipes = const [],
  });

  final AgentHubOperationStatus status;
  final AgentHubLifecycleAction action;
  final String recipeId;
  final String nativeStatus;
  final String ownership;
  final List<String> events;
  final List<AgentHubRecipe> recipes;

  bool get ok =>
      status == AgentHubOperationStatus.completed ||
      status == AgentHubOperationStatus.externalProtected ||
      status == AgentHubOperationStatus.cancelled;
}

/// Five-platform ordinary-capability lookup. Flutter renders; Rust owns use-case.
abstract interface class AgentHubCapabilityPort {
  bool supports({
    required AgentHubRuntimePlatform platform,
    required AgentHubLifecycleAction action,
  });
}

/// Typed Hub catalog + plan/confirm/install/update/uninstall/verify/rescan.
///
/// Callers must not invent a GUI argv/stdio product path. Recipe identity
/// comes from the native warehouse catalog, never a second Dart recipe list.
abstract interface class AgentHubEnginePort {
  /// Last successful catalog snapshot. Long-lived engines keep this across
  /// destination rebuilds so Hub can paint immediately on reopen.
  AgentHubCatalogSnapshot? get cachedCatalog;

  /// Warehouse cards when [recipeId] is empty. One live local lookup when set.
  Future<AgentHubCatalogSnapshot> catalog({String recipeId = ''});

  Future<AgentHubOperationResult> plan(AgentHubPlanRequest request);

  Future<AgentHubOperationResult> confirm(AgentHubConfirmRequest request);

  Future<AgentHubOperationResult> install(AgentHubInstallRequest request);

  Future<AgentHubOperationResult> update(AgentHubUpdateRequest request);

  Future<AgentHubOperationResult> uninstall(AgentHubUninstallRequest request);

  Future<AgentHubOperationResult> verify(AgentHubVerifyRequest request);

  Future<AgentHubOperationResult> rescan(AgentHubRescanRequest request);
}
