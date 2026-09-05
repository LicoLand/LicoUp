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
  bool _busy = false;
  bool _failed = false;

  AgentHubCatalogSnapshot? get catalog => _catalog;
  bool get busy => _busy;
  bool get failed => _failed;
  bool get resolving => _resolvingRecipeIds.isNotEmpty;

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
    final active = _refreshFuture;
    if (active != null) {
      final snapshot = await active;
      return _snapshotForRecipe(snapshot, id);
    }
    _resolvingRecipeIds.add(id);
    publishChange();
    try {
      final snapshot = await _engine.catalog(recipeId: id);
      final live = _recipeFrom(snapshot, id);
      if (live != null) {
        _replaceRecipe(live);
        publishChange();
      }
      return snapshot;
    } on Object {
      return const AgentHubCatalogSnapshot(recipes: [], ok: false);
    } finally {
      _resolvingRecipeIds.remove(id);
      publishChange();
    }
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

        final recipes = await Future.wait([
          for (final recipe in root.recipes) _resolveRecipe(recipe),
        ]);
        final resolved = AgentHubCatalogSnapshot(
          recipes: recipes,
          scanGeneration: root.scanGeneration,
          ok: root.ok,
        );
        _catalog = resolved;
        return resolved;
      } else {
        _failed = true;
      }
      return root;
    } on Object {
      _failed = true;
      return _catalog ?? const AgentHubCatalogSnapshot(recipes: [], ok: false);
    } finally {
      _busy = false;
      _resolvingRecipeIds.clear();
      publishChange();
    }
  }

  Future<AgentHubRecipe> _resolveRecipe(AgentHubRecipe fallback) async {
    var resolved = fallback;
    try {
      final snapshot = await _engine.catalog(recipeId: fallback.id);
      resolved = _recipeFrom(snapshot, fallback.id) ?? fallback;
      _replaceRecipe(resolved);
    } on Object {
      // One failed probe must not discard the warehouse card or block peers.
    } finally {
      _resolvingRecipeIds.remove(fallback.id);
      publishChange();
    }
    return resolved;
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

  AgentHubCatalogSnapshot _snapshotForRecipe(
    AgentHubCatalogSnapshot snapshot,
    String recipeId,
  ) {
    final recipe = _recipeFrom(snapshot, recipeId);
    return AgentHubCatalogSnapshot(
      recipes: recipe == null ? const [] : [recipe],
      scanGeneration: snapshot.scanGeneration,
      ok: recipe != null,
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
