import 'dart:convert';

import 'package:licoup/src/contracts/agent_hub.dart';

typedef AgentHubNativeInvoke =
    Future<Map<String, dynamic>> Function(List<String> arguments);

/// Typed ordinary-lifecycle facade while native FFI is unwired.
final class UnwiredAgentHubEngine implements AgentHubEnginePort {
  const UnwiredAgentHubEngine();

  @override
  Future<AgentHubCatalogSnapshot> catalog() async {
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

  @override
  Future<AgentHubCatalogSnapshot> catalog() async {
    try {
      final raw = await _invoke(const ['agent-hub', 'catalog']);
      return _ingestCatalog(raw);
    } on Object {
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
        jsonEncode({'discoveryCandidates': _discovery}),
      ]);
      return _planResult(recipeId, raw);
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
        jsonEncode({'discoveryCandidates': _discovery}),
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
    String operation,
  ) async {
    final planned = await plan(
      AgentHubPlanRequest(recipeId: recipeId, operation: operation),
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
      AgentHubInstallRequest(recipeId: recipeId, operation: operation),
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
    final snapshot = await catalog();
    if (!snapshot.ok) {
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

  AgentHubCatalogSnapshot _ingestCatalog(Map<String, dynamic> raw) {
    final cards = raw['cards'];
    if (raw['ok'] != true || cards is! List) {
      return const AgentHubCatalogSnapshot(recipes: [], ok: false);
    }
    final recipes = cards
        .whereType<Map>()
        .map(
          (card) =>
              AgentHubRecipe.fromNativeCard(Map<String, dynamic>.from(card)),
        )
        .where((recipe) => recipe.id.isNotEmpty)
        .toList();
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
    return AgentHubCatalogSnapshot(
      recipes: recipes,
      scanGeneration: generation is int
          ? generation
          : int.tryParse('$generation') ?? 0,
      ok: true,
    );
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
