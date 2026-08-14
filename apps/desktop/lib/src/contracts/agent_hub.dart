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
      '' => 'official',
      _ => kind,
    };
  }

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
    );
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
  });

  final String recipeId;
  final String operation;
}

final class AgentHubConfirmRequest {
  const AgentHubConfirmRequest({required this.recipeId});

  final String recipeId;
}

final class AgentHubInstallRequest {
  const AgentHubInstallRequest({
    required this.recipeId,
    this.operation = 'install',
    this.cancel = false,
  });

  final String recipeId;
  final String operation;
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
  Future<AgentHubCatalogSnapshot> catalog();

  Future<AgentHubOperationResult> plan(AgentHubPlanRequest request);

  Future<AgentHubOperationResult> confirm(AgentHubConfirmRequest request);

  Future<AgentHubOperationResult> install(AgentHubInstallRequest request);

  Future<AgentHubOperationResult> update(AgentHubUpdateRequest request);

  Future<AgentHubOperationResult> uninstall(AgentHubUninstallRequest request);

  Future<AgentHubOperationResult> verify(AgentHubVerifyRequest request);

  Future<AgentHubOperationResult> rescan(AgentHubRescanRequest request);
}
