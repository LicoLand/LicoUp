import 'dart:convert';

import 'package:licoup/src/contracts/agent_hub.dart';

typedef AgentHubNativeInvoke =
    Future<Map<String, dynamic>> Function(List<String> arguments);

/// Typed ordinary-lifecycle facade while native FFI is unwired.
final class UnwiredAgentHubEngine implements AgentHubEnginePort {
  const UnwiredAgentHubEngine();

  @override
  AgentHubCatalogSnapshot? get cachedCatalog => null;

  @override
  Future<AgentHubCatalogSnapshot> catalog({String recipeId = ''}) async {
    return const AgentHubCatalogSnapshot(recipes: [], ok: false);
  }

  @override
  Future<AgentHubOperationResult> plan(AgentHubPlanRequest request) async {
    return _unwired(AgentHubLifecycleAction.plan, request.recipeId);
  }

  @override
  Future<AgentHubOperationResult> confirm(
    AgentHubConfirmRequest request,
  ) async {
    return _unwired(AgentHubLifecycleAction.confirm, request.recipeId);
  }

  @override
  Future<AgentHubOperationResult> install(
    AgentHubInstallRequest request,
  ) async {
    return _unwired(AgentHubLifecycleAction.install, request.recipeId);
  }

  @override
  Future<AgentHubOperationResult> verify(AgentHubVerifyRequest request) async {
    return _unwired(AgentHubLifecycleAction.verify, request.recipeId);
  }

  @override
  Future<AgentHubOperationResult> update(AgentHubUpdateRequest request) async {
    return _unwired(AgentHubLifecycleAction.update, request.recipeId);
  }

  @override
  Future<AgentHubOperationResult> uninstall(
    AgentHubUninstallRequest request,
  ) async {
    return _unwired(AgentHubLifecycleAction.uninstall, request.recipeId);
  }

  @override
  Future<AgentHubOperationResult> rescan(AgentHubRescanRequest request) async {
    return _unwired(AgentHubLifecycleAction.rescan, request.recipeId);
  }

  AgentHubOperationResult _unwired(
    AgentHubLifecycleAction action,
    String recipeId,
  ) {
    return AgentHubOperationResult(
      status: AgentHubOperationStatus.nativeNotWired,
      action: action,
      recipeId: recipeId,
    );
  }
}

/// Pass-through to native `agent-hub catalog|plan|apply`.
///
/// Consumes one native catalog snapshot for discovery facts. Does not scan
/// per card in Dart. Confirmation tokens stay in this engine; argv is never
/// copied into UI results.
final class NativeAgentHubEngine implements AgentHubEnginePort {
  NativeAgentHubEngine({required AgentHubNativeInvoke invoke})
    : _invoke = invoke;

  final AgentHubNativeInvoke _invoke;
  final List<Map<String, dynamic>> _discovery = [];
  final Map<String, String> _confirmations = {};
  final Set<String> _confirmed = {};
  final Map<String, String> _plannedChannels = {};
  final Map<String, String> _plannedVersions = {};
  AgentHubCatalogSnapshot? _cachedCatalog;

  @override
  AgentHubCatalogSnapshot? get cachedCatalog => _cachedCatalog;

  @override
  Future<AgentHubCatalogSnapshot> catalog({String recipeId = ''}) async {
    try {
      final id = recipeId.trim();
      final raw = await _invoke([
        'agent-hub',
        'catalog',
        if (id.isNotEmpty) ...['--agent-id', id],
      ]);
      final snapshot = _ingestCatalog(raw, merge: id.isNotEmpty);
      if (snapshot.ok) {
        return snapshot;
      }
      if (_cachedCatalog != null) {
        return AgentHubCatalogSnapshot(
          recipes: _cachedCatalog!.recipes,
          scanGeneration: _cachedCatalog!.scanGeneration,
          ok: false,
        );
      }
      return snapshot;
    } on Object {
      if (_cachedCatalog != null) {
        return AgentHubCatalogSnapshot(
          recipes: _cachedCatalog!.recipes,
          scanGeneration: _cachedCatalog!.scanGeneration,
          ok: false,
        );
      }
      return const AgentHubCatalogSnapshot(recipes: [], ok: false);
    }
  }

  @override
  Future<AgentHubOperationResult> plan(AgentHubPlanRequest request) async {
    final recipeId = request.recipeId.trim();
    if (recipeId.isEmpty) {
      return _failed(AgentHubLifecycleAction.plan, recipeId);
    }
    await _ensureDiscovery();
    try {
      final raw = await _invoke([
        'agent-hub',
        'plan',
        '--agent-id',
        recipeId,
        '--operation',
        request.operation,
        '--stdin-json',
        jsonEncode(_stdinPayload(request.channelId, request.version)),
      ]);
      final result = _planResult(recipeId, raw);
      if (result.ok) {
        if (request.channelId.trim().isNotEmpty) {
          _plannedChannels[recipeId] = request.channelId.trim();
        }
        if (request.version.trim().isNotEmpty) {
          _plannedVersions[recipeId] = request.version.trim();
        }
      }
      return result;
    } on Object {
      return _failed(AgentHubLifecycleAction.plan, recipeId);
    }
  }

  @override
  Future<AgentHubOperationResult> confirm(
    AgentHubConfirmRequest request,
  ) async {
    final recipeId = request.recipeId.trim();
    final token = _confirmations[recipeId];
    if (token == null || token.isEmpty) {
      return AgentHubOperationResult(
        status: AgentHubOperationStatus.failed,
        action: AgentHubLifecycleAction.confirm,
        recipeId: recipeId,
        nativeStatus: 'confirmation_required',
      );
    }
    _confirmed.add(recipeId);
    return AgentHubOperationResult(
      status: AgentHubOperationStatus.completed,
      action: AgentHubLifecycleAction.confirm,
      recipeId: recipeId,
      nativeStatus: 'confirmed',
      events: const ['confirmed'],
    );
  }

  @override
  Future<AgentHubOperationResult> install(
    AgentHubInstallRequest request,
  ) async {
    final recipeId = request.recipeId.trim();
    final token = _confirmations[recipeId];
    if (token == null || token.isEmpty) {
      return AgentHubOperationResult(
        status: AgentHubOperationStatus.failed,
        action: AgentHubLifecycleAction.install,
        recipeId: recipeId,
        nativeStatus: 'confirmation_required',
      );
    }
    await _ensureDiscovery();
    try {
      final channelId = request.channelId.trim().isNotEmpty
          ? request.channelId.trim()
          : (_plannedChannels[recipeId] ?? '');
      final version = request.version.trim().isNotEmpty
          ? request.version.trim()
          : (_plannedVersions[recipeId] ?? 'latest');
      final raw = await _invoke([
        'agent-hub',
        'apply',
        '--agent-id',
        recipeId,
        '--operation',
        request.operation,
        '--confirmation',
        token,
        if (request.cancel) '--cancel',
        '--stdin-json',
        jsonEncode(_stdinPayload(channelId, version)),
      ]);
      final result = _applyResult(recipeId, raw);
      if (result.ok) {
        _confirmations.remove(recipeId);
        _confirmed.remove(recipeId);
      }
      return result;
    } on Object {
      return _failed(AgentHubLifecycleAction.install, recipeId);
    }
  }

  @override
  Future<AgentHubOperationResult> update(AgentHubUpdateRequest request) async {
    return _managedApply(
      AgentHubLifecycleAction.update,
      request.recipeId,
      'update',
    );
  }

  @override
  Future<AgentHubOperationResult> uninstall(
    AgentHubUninstallRequest request,
  ) async {
    return _managedApply(
      AgentHubLifecycleAction.uninstall,
      request.recipeId,
      'uninstall',
    );
  }

  @override
  Future<AgentHubOperationResult> verify(AgentHubVerifyRequest request) async {
    return _refreshSnapshot(AgentHubLifecycleAction.verify, request.recipeId);
  }

  @override
  Future<AgentHubOperationResult> rescan(AgentHubRescanRequest request) async {
    return _refreshSnapshot(AgentHubLifecycleAction.rescan, request.recipeId);
  }

  Future<AgentHubOperationResult> _managedApply(
    AgentHubLifecycleAction action,
    String recipeId,
    String operation, {
    String channelId = '',
    String version = 'latest',
  }) async {
    final planned = await plan(
      AgentHubPlanRequest(
        recipeId: recipeId,
        operation: operation,
        channelId: channelId,
        version: version,
      ),
    );
    if (planned.status == AgentHubOperationStatus.externalProtected) {
      return AgentHubOperationResult(
        status: AgentHubOperationStatus.externalProtected,
        action: action,
        recipeId: recipeId,
        nativeStatus: planned.nativeStatus,
        ownership: planned.ownership,
        events: planned.events,
        recipes: planned.recipes,
      );
    }
    if (!planned.ok) {
      return AgentHubOperationResult(
        status: planned.status,
        action: action,
        recipeId: recipeId,
        nativeStatus: planned.nativeStatus,
        ownership: planned.ownership,
        events: planned.events,
        recipes: planned.recipes,
      );
    }
    final confirmed = await confirm(AgentHubConfirmRequest(recipeId: recipeId));
    if (!confirmed.ok) {
      return AgentHubOperationResult(
        status: confirmed.status,
        action: action,
        recipeId: recipeId,
        nativeStatus: confirmed.nativeStatus,
        events: confirmed.events,
      );
    }
    final applied = await install(
      AgentHubInstallRequest(
        recipeId: recipeId,
        operation: operation,
        channelId: channelId,
        version: version,
      ),
    );
    return AgentHubOperationResult(
      status: applied.status,
      action: action,
      recipeId: recipeId,
      nativeStatus: applied.nativeStatus,
      ownership: applied.ownership,
      events: applied.events,
      recipes: applied.recipes,
    );
  }

  Future<AgentHubOperationResult> _refreshSnapshot(
    AgentHubLifecycleAction action,
    String recipeId,
  ) async {
    final snapshot = await catalog(recipeId: recipeId);
    if (!snapshot.ok && snapshot.recipes.isEmpty) {
      return _failed(action, recipeId);
    }
    final recipe = snapshot.recipes
        .where((item) => item.id == recipeId)
        .firstOrNull;
    final nativeStatus = _terminalLifecycle(recipe);
    return AgentHubOperationResult(
      status: AgentHubOperationStatus.completed,
      action: action,
      recipeId: recipeId,
      nativeStatus: nativeStatus,
      ownership: recipe?.ownership ?? '',
      recipes: snapshot.recipes,
    );
  }

  String _terminalLifecycle(AgentHubRecipe? recipe) {
    if (recipe == null) {
      return 'absent';
    }
    final lifecycle = recipe.lifecycle.trim();
    if (lifecycle == 'verifying' ||
        lifecycle == 'rescanning' ||
        lifecycle == 'applying') {
      if (recipe.ownership == 'external') {
        return 'external';
      }
      return recipe.present ? 'discovered' : 'absent';
    }
    if (lifecycle.isNotEmpty) {
      return lifecycle;
    }
    if (recipe.ownership == 'external') {
      return 'external';
    }
    return recipe.present ? 'discovered' : 'absent';
  }

  Future<void> _ensureDiscovery() async {
    if (_discovery.isNotEmpty) {
      return;
    }
    await catalog();
  }

  Map<String, dynamic> _stdinPayload(String channelId, String version) {
    return <String, dynamic>{
      'discoveryCandidates': _discovery,
      if (channelId.trim().isNotEmpty) 'channelId': channelId.trim(),
      if (version.trim().isNotEmpty) 'version': version.trim(),
    };
  }

  AgentHubCatalogSnapshot _ingestCatalog(
    Map<String, dynamic> raw, {
    bool merge = false,
  }) {
    final cards = raw['cards'];
    if (raw['ok'] != true || cards is! List) {
      return const AgentHubCatalogSnapshot(recipes: [], ok: false);
    }
    final incoming = cards
        .whereType<Map>()
        .map(
          (card) =>
              AgentHubRecipe.fromNativeCard(Map<String, dynamic>.from(card)),
        )
        .where((recipe) => recipe.id.isNotEmpty)
        .toList();
    final recipes = merge && _cachedCatalog != null
        ? _mergeRecipes(_cachedCatalog!.recipes, incoming)
        : incoming;
    _discovery
      ..clear()
      ..addAll(
        recipes.map(
          (recipe) => <String, dynamic>{
            'target': recipe.id,
            'present': recipe.present,
            'status': recipe.present ? 'detected' : 'absent',
          },
        ),
      );
    final generation = raw['scanGeneration'];
    final snapshot = AgentHubCatalogSnapshot(
      recipes: recipes,
      scanGeneration: generation is int
          ? generation
          : int.tryParse('$generation') ??
                (_cachedCatalog?.scanGeneration ?? 0),
      ok: true,
    );
    _cachedCatalog = snapshot;
    return snapshot;
  }

  List<AgentHubRecipe> _mergeRecipes(
    List<AgentHubRecipe> current,
    List<AgentHubRecipe> incoming,
  ) {
    if (incoming.isEmpty) {
      return current;
    }
    final byId = {for (final recipe in incoming) recipe.id: recipe};
    final merged = [
      for (final recipe in current) byId.remove(recipe.id) ?? recipe,
    ];
    merged.addAll(byId.values);
    return merged;
  }

  AgentHubOperationResult _planResult(
    String recipeId,
    Map<String, dynamic> raw,
  ) {
    final nativeStatus = (raw['status'] as String? ?? '').trim();
    if (nativeStatus == 'external_protected') {
      return AgentHubOperationResult(
        status: AgentHubOperationStatus.externalProtected,
        action: AgentHubLifecycleAction.plan,
        recipeId: recipeId,
        nativeStatus: nativeStatus,
        ownership: (raw['ownership'] as String? ?? '').trim(),
      );
    }
    if (raw['ok'] != true || nativeStatus.isEmpty) {
      return _failed(AgentHubLifecycleAction.plan, recipeId, nativeStatus);
    }
    final token = (raw['confirmation'] as String? ?? '').trim();
    if (token.isNotEmpty) {
      _confirmations[recipeId] = token;
      _confirmed.remove(recipeId);
    }
    return AgentHubOperationResult(
      status: AgentHubOperationStatus.completed,
      action: AgentHubLifecycleAction.plan,
      recipeId: recipeId,
      nativeStatus: nativeStatus,
      ownership: (raw['ownership'] as String? ?? '').trim(),
      events: const ['planned'],
    );
  }

  AgentHubOperationResult _applyResult(
    String recipeId,
    Map<String, dynamic> raw,
  ) {
    final nativeStatus = (raw['status'] as String? ?? '').trim();
    final events = _eventPhases(raw['events']);
    if (nativeStatus == 'cancelled') {
      return AgentHubOperationResult(
        status: AgentHubOperationStatus.cancelled,
        action: AgentHubLifecycleAction.install,
        recipeId: recipeId,
        nativeStatus: nativeStatus,
        events: events,
      );
    }
    if (nativeStatus == 'external_protected') {
      return AgentHubOperationResult(
        status: AgentHubOperationStatus.externalProtected,
        action: AgentHubLifecycleAction.install,
        recipeId: recipeId,
        nativeStatus: nativeStatus,
        ownership: (raw['ownership'] as String? ?? '').trim(),
        events: events,
      );
    }
    if (raw['ok'] != true) {
      return _failed(AgentHubLifecycleAction.install, recipeId, nativeStatus);
    }
    return AgentHubOperationResult(
      status: AgentHubOperationStatus.completed,
      action: AgentHubLifecycleAction.install,
      recipeId: recipeId,
      nativeStatus: nativeStatus,
      ownership: (raw['ownership'] as String? ?? '').trim(),
      events: events,
    );
  }

  List<String> _eventPhases(Object? raw) {
    if (raw is! List) {
      return const [];
    }
    return raw
        .whereType<Map>()
        .map((event) => (event['phase'] as String? ?? '').trim())
        .where((phase) => phase.isNotEmpty)
        .toList();
  }

  AgentHubOperationResult _failed(
    AgentHubLifecycleAction action,
    String recipeId, [
    String nativeStatus = 'failed',
  ]) {
    return AgentHubOperationResult(
      status: AgentHubOperationStatus.failed,
      action: action,
      recipeId: recipeId,
      nativeStatus: nativeStatus.isEmpty ? 'failed' : nativeStatus,
      events: const ['failed'],
    );
  }
}
