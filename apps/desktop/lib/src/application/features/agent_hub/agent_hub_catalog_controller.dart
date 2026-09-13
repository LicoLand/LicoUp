import 'dart:async';

import 'package:licoup/src/application/state/application_signal.dart';

import 'package:licoup/src/contracts/agent_hub.dart';

/// Application-owned Agent Hub catalog projection.
///
/// The Shell and feature panels receive this controller instead of creating
/// their own engine, so rebuilds and remounts cannot duplicate a native
/// catalog request. Refreshes are single-flight; a settled failure keeps the
/// last valid projection while exposing a stable failed flag.
final class AgentHubCatalogController extends ApplicationStateOwner {
  AgentHubCatalogController({required AgentHubEnginePort engine})
    : _engine = engine,
      _catalog = engine.cachedCatalog;

  final AgentHubEnginePort _engine;
  AgentHubCatalogSnapshot? _catalog;
  Future<AgentHubCatalogSnapshot>? _refreshFuture;
  final Set<String> _resolvingRecipeIds = {};
  final Set<String> _failedRecipeIds = {};
  final Map<String, Future<AgentHubCatalogSnapshot>> _recipeLoads = {};
  bool _busy = false;
  bool _failed = false;

  AgentHubCatalogSnapshot? get catalog => _catalog;
  bool get busy => _busy;
  bool get failed => _failed;
  bool get resolving => _resolvingRecipeIds.isNotEmpty;
  bool isRecipeFailed(String recipeId) => _failedRecipeIds.contains(recipeId);

  bool isRecipeResolving(String recipeId) {
    return _resolvingRecipeIds.contains(recipeId);
  }

  /// One shared catalog refresh. Later calls join the in-flight request.
  Future<AgentHubCatalogSnapshot> refresh() {
    final active = _refreshFuture;
    if (active != null) return active;
    late final Future<AgentHubCatalogSnapshot> refresh;
    refresh = _load().whenComplete(() {
      if (identical(_refreshFuture, refresh)) {
        _refreshFuture = null;
      }
    });
    _refreshFuture = refresh;
    return refresh;
  }

  /// Refreshes one card after a lifecycle mutation and merges the resolved
  /// native state into the shared projection.
  Future<AgentHubCatalogSnapshot> refreshRecipe(String recipeId) async {
    final id = recipeId.trim();
    if (id.isEmpty) {
      return const AgentHubCatalogSnapshot(recipes: [], ok: false);
    }
    final active = _recipeLoads[id];
    if (active != null) await active;
    return _inspectRecipe(id);
  }

  Future<AgentHubOperationResult> runLifecycle(
    AgentHubLifecycleAction action, {
    required String recipeId,
    String channelId = '',
    String version = 'latest',
  }) {
    return switch (action) {
      AgentHubLifecycleAction.plan => _engine.plan(
        AgentHubPlanRequest(
          recipeId: recipeId,
          channelId: channelId,
          version: version,
        ),
      ),
      AgentHubLifecycleAction.confirm => _engine.confirm(
        AgentHubConfirmRequest(recipeId: recipeId),
      ),
      AgentHubLifecycleAction.install => _engine.install(
        AgentHubInstallRequest(
          recipeId: recipeId,
          channelId: channelId,
          version: version,
        ),
      ),
      AgentHubLifecycleAction.update => _engine.update(
        AgentHubUpdateRequest(recipeId: recipeId),
      ),
      AgentHubLifecycleAction.uninstall => _engine.uninstall(
        AgentHubUninstallRequest(recipeId: recipeId),
      ),
      AgentHubLifecycleAction.verify => _engine.verify(
        AgentHubVerifyRequest(recipeId: recipeId),
      ),
      AgentHubLifecycleAction.rescan => _engine.rescan(
        AgentHubRescanRequest(recipeId: recipeId),
      ),
    };
  }

  Future<AgentHubCatalogSnapshot> _load() async {
    _busy = true;
    _failedRecipeIds.clear();
    _resolvingRecipeIds.addAll(
      _catalog?.recipes.map((recipe) => recipe.id) ?? const <String>[],
    );
    publishChange();
    try {
      final root = await _engine.catalog();
      if (root.ok || root.recipes.isNotEmpty) {
        _catalog = root;
        _failed = false;
        _resolvingRecipeIds
          ..clear()
          ..addAll(root.recipes.map((recipe) => recipe.id));
        publishChange();

        if (root.recipes.isEmpty) return root;
        final settled = Completer<void>();
        var remaining = root.recipes.length;
        for (final recipe in root.recipes) {
          unawaited(
            _inspectRecipe(recipe.id).whenComplete(() {
              remaining--;
              if (remaining == 0) settled.complete();
            }),
          );
        }
        // Each result is published by its own task. This future only keeps
        // refresh single-flight until every requested inspection settles.
        await settled.future;
        return _catalog ?? root;
      } else {
        _failed = true;
      }
      return root;
    } on Object {
      _failed = true;
      return _catalog ?? const AgentHubCatalogSnapshot(recipes: [], ok: false);
    } finally {
      _busy = false;
      _resolvingRecipeIds.retainAll(_recipeLoads.keys);
      publishChange();
    }
  }

  Future<AgentHubCatalogSnapshot> _inspectRecipe(String id) {
    final active = _recipeLoads[id];
    if (active != null) return active;
    final next = _resolveRecipe(id).whenComplete(() {
      _recipeLoads.remove(id);
    });
    _recipeLoads[id] = next;
    return next;
  }

  Future<AgentHubCatalogSnapshot> _resolveRecipe(String id) async {
    _resolvingRecipeIds.add(id);
    publishChange();
    try {
      final snapshot = await _engine.catalog(recipeId: id, live: true);
      final recipe = _recipeFrom(snapshot, id);
      if (snapshot.ok && recipe != null) {
        _replaceRecipe(recipe);
        _failedRecipeIds.remove(id);
      } else {
        _failedRecipeIds.add(id);
      }
      return snapshot;
    } on Object {
      _failedRecipeIds.add(id);
      return const AgentHubCatalogSnapshot(recipes: [], ok: false);
    } finally {
      _resolvingRecipeIds.remove(id);
      publishChange();
    }
  }

  void _replaceRecipe(AgentHubRecipe recipe) {
    final current = _catalog;
    if (current == null) {
      _catalog = AgentHubCatalogSnapshot(recipes: [recipe]);
      return;
    }
    final recipes = List<AgentHubRecipe>.from(current.recipes);
    final index = recipes.indexWhere((candidate) => candidate.id == recipe.id);
    if (index < 0) {
      recipes.add(recipe);
    } else {
      recipes[index] = recipe;
    }
    _catalog = AgentHubCatalogSnapshot(
      recipes: recipes,
      scanGeneration: current.scanGeneration,
      ok: current.ok,
    );
  }

  AgentHubRecipe? _recipeFrom(
    AgentHubCatalogSnapshot snapshot,
    String recipeId,
  ) {
    return snapshot.recipes
        .where((recipe) => recipe.id == recipeId)
        .firstOrNull;
  }
}
