import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:licoup/src/application/features/agent_hub/agent_hub_capability_port.dart';
import 'package:licoup/src/application/features/agent_hub/agent_hub_engine.dart';
import 'package:licoup/src/contracts/agent_hub.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agent_hub/ui/agent_hub_install_dialog.dart';
import 'package:licoup/src/frontend/features/agent_hub/ui/agent_hub_summary_visit.dart';
import 'package:licoup/src/frontend/features/agent_hub/ui/agent_hub_uninstall_dialog.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/tokens/messaging_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/ui/agent_brand_icon.dart';
import 'package:licoup/src/frontend/shared/ui/lico_activity_animations.dart';
import 'package:licoup/src/frontend/shared/ui/lico_content_spacing.dart';
import 'package:licoup/src/frontend/shared/ui/lico_icon_button.dart';
import 'package:licoup/src/frontend/shared/ui/lico_pane_scaffold.dart';
import 'package:licoup/src/frontend/shared/ui/lico_radius.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

const double _hubCardInset = LicoContentSpacing.compact;
const double _hubCardHorizontalInset = LicoContentSpacing.item;
const double _hubListIconSize = 40;
const double _hubListSummaryFontSize = 12;
const double _hubListSummaryLineHeight = 1.4;
const int _hubListSummaryMaxLines = 2;
const double _hubListSummaryHeight =
    _hubListSummaryFontSize *
    _hubListSummaryLineHeight *
    _hubListSummaryMaxLines;
const double _hubListNameHeight = 20;
const double _hubListIntroHeight =
    _hubListIconSize <
        (_hubListNameHeight + LicoContentSpacing.inline + _hubListSummaryHeight)
    ? _hubListNameHeight + LicoContentSpacing.inline + _hubListSummaryHeight
    : _hubListIconSize;
const double _hubCardFooterExtent = 24;
const double _hubCardExtent =
    _hubCardInset * 2 +
    _hubListIntroHeight +
    LicoContentSpacing.compact +
    1 +
    LicoContentSpacing.compact +
    _hubCardFooterExtent;
const double _hubFooterActionGap = LicoContentSpacing.compact;
const double _hubFooterActionFontSize = 12;
const double _hubChipIconSize = 13;
const BorderRadius _hubChipBorderRadius = BorderRadius.all(
  Radius.circular(999),
);
const EdgeInsets _hubChipPadding = EdgeInsets.symmetric(
  horizontal: 8,
  vertical: 4,
);

typedef AgentHubCatalogOrder =
    List<AgentHubRecipe> Function(List<AgentHubRecipe> recipes);

List<AgentHubRecipe> shuffleAgentHubRecipes(List<AgentHubRecipe> recipes) {
  final next = List<AgentHubRecipe>.from(recipes);
  next.shuffle(math.Random());
  return next;
}

typedef AgentHubHomepageOpener = Future<bool> Function(Uri uri);
typedef AgentHubOpenAgent = void Function(String recipeId);

/// Agent Hub body: native catalog cards with plan/confirm/install/verify/rescan.
final class AgentHubPanel extends StatefulWidget {
  const AgentHubPanel({
    super.key,
    this.engine = const UnwiredAgentHubEngine(),
    this.capabilities = const StaticAgentHubCapabilityPort(),
    this.openHomepage,
    this.onOpenAgent,
    this.orderRecipes = shuffleAgentHubRecipes,
  });

  final AgentHubEnginePort engine;
  final AgentHubCapabilityPort capabilities;
  final AgentHubHomepageOpener? openHomepage;
  final AgentHubOpenAgent? onOpenAgent;
  final AgentHubCatalogOrder orderRecipes;

  Future<AgentHubOperationResult> runLifecycle(
    AgentHubLifecycleAction action, {
    required String recipeId,
    String channelId = '',
    String version = 'latest',
  }) {
    return switch (action) {
      AgentHubLifecycleAction.plan => engine.plan(
        AgentHubPlanRequest(
          recipeId: recipeId,
          channelId: channelId,
          version: version,
        ),
      ),
      AgentHubLifecycleAction.confirm => engine.confirm(
        AgentHubConfirmRequest(recipeId: recipeId),
      ),
      AgentHubLifecycleAction.install => engine.install(
        AgentHubInstallRequest(
          recipeId: recipeId,
          channelId: channelId,
          version: version,
        ),
      ),
      AgentHubLifecycleAction.update => engine.update(
        AgentHubUpdateRequest(recipeId: recipeId),
      ),
      AgentHubLifecycleAction.uninstall => engine.uninstall(
        AgentHubUninstallRequest(recipeId: recipeId),
      ),
      AgentHubLifecycleAction.verify => engine.verify(
        AgentHubVerifyRequest(recipeId: recipeId),
      ),
      AgentHubLifecycleAction.rescan => engine.rescan(
        AgentHubRescanRequest(recipeId: recipeId),
      ),
    };
  }

  @override
  State<AgentHubPanel> createState() => _AgentHubPanelState();
}

final class _AgentHubPanelState extends State<AgentHubPanel> {
  List<AgentHubRecipe> _recipes = const [];
  bool _loading = true;
  bool _catalogFailed = false;
  String _busyRecipeId = '';
  String? _detailRecipeId;
  int _loadGeneration = 0;
  final Set<String> _resolving = {};
  final Map<String, List<String>> _events = {};
  final Set<String> _visitFailed = {};

  bool get _discovering => _resolving.isNotEmpty;

  AgentHubRecipe? get _detailRecipe {
    final id = _detailRecipeId;
    if (id == null) {
      return null;
    }
    return _recipes.where((recipe) => recipe.id == id).firstOrNull;
  }

  @override
  void initState() {
    super.initState();
    _applyCache(widget.engine.cachedCatalog);
    unawaited(_loadCatalog());
  }

  @override
  void didUpdateWidget(covariant AgentHubPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.engine, widget.engine)) {
      _applyCache(widget.engine.cachedCatalog);
      unawaited(_loadCatalog());
    }
  }

  void _applyCache(AgentHubCatalogSnapshot? snapshot) {
    if (snapshot == null || snapshot.recipes.isEmpty) {
      return;
    }
    _recipes = List<AgentHubRecipe>.from(widget.orderRecipes(snapshot.recipes));
    _resolving
      ..clear()
      ..addAll(_recipes.map((recipe) => recipe.id));
    _loading = false;
    _catalogFailed = false;
  }

  Future<void> _loadCatalog() async {
    final generation = ++_loadGeneration;
    if (mounted) {
      setState(() {
        if (_recipes.isEmpty) {
          _loading = true;
        } else {
          _resolving
            ..clear()
            ..addAll(_recipes.map((recipe) => recipe.id));
        }
      });
    }
    try {
      final snapshot = await widget.engine.catalog();
      if (!mounted || generation != _loadGeneration) {
        return;
      }
      if (snapshot.ok || snapshot.recipes.isNotEmpty) {
        final ordered = List<AgentHubRecipe>.from(
          widget.orderRecipes(snapshot.recipes),
        );
        setState(() {
          _recipes = ordered;
          _catalogFailed = false;
          _loading = false;
          _busyRecipeId = '';
          _visitFailed.clear();
          _resolving
            ..clear()
            ..addAll(ordered.map((recipe) => recipe.id));
          if (_detailRecipeId != null &&
              ordered.every((recipe) => recipe.id != _detailRecipeId)) {
            _detailRecipeId = null;
          }
        });
        await _discoverCards(ordered, generation);
        return;
      }
      setState(() {
        _catalogFailed = _recipes.isEmpty;
        _loading = false;
        _busyRecipeId = '';
        _resolving.clear();
      });
    } on Object {
      if (!mounted || generation != _loadGeneration) {
        return;
      }
      setState(() {
        _catalogFailed = _recipes.isEmpty;
        _loading = false;
        _busyRecipeId = '';
        _resolving.clear();
      });
    }
  }

  Future<void> _discoverCards(
    List<AgentHubRecipe> recipes,
    int generation,
  ) async {
    await Future.wait([
      for (final recipe in recipes) _discoverCard(recipe.id, generation),
    ]);
  }

  Future<void> _discoverCard(String recipeId, int generation) async {
    try {
      final snapshot = await widget.engine.catalog(recipeId: recipeId);
      if (!mounted || generation != _loadGeneration) {
        return;
      }
      final live = snapshot.recipes
          .where((recipe) => recipe.id == recipeId)
          .firstOrNull;
      setState(() {
        if (live != null) {
          final index = _recipes.indexWhere((recipe) => recipe.id == recipeId);
          if (index >= 0) {
            _recipes[index] = live;
          }
        }
        _resolving.remove(recipeId);
      });
    } on Object {
      if (!mounted || generation != _loadGeneration) {
        return;
      }
      setState(() => _resolving.remove(recipeId));
    }
  }

  Future<void> _run(
    AgentHubLifecycleAction action, {
    required String recipeId,
    String channelId = '',
    String version = 'latest',
  }) async {
    setState(() => _busyRecipeId = recipeId);
    try {
      final result = await widget.runLifecycle(
        action,
        recipeId: recipeId,
        channelId: channelId,
        version: version,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _busyRecipeId = '';
        _events[recipeId] = result.events
            .where((phase) => phase != 'verifying' && phase != 'rescanning')
            .toList();
        for (final live in result.recipes) {
          final index = _recipes.indexWhere((recipe) => recipe.id == live.id);
          if (index >= 0) {
            _recipes[index] = live;
          }
        }
        _catalogFailed = false;
        if (action == AgentHubLifecycleAction.uninstall && result.ok) {
          _detailRecipeId = null;
        }
      });
      if ((action == AgentHubLifecycleAction.install ||
              action == AgentHubLifecycleAction.update ||
              action == AgentHubLifecycleAction.uninstall) &&
          result.ok) {
        setState(() => _resolving.add(recipeId));
        await _discoverCard(recipeId, _loadGeneration);
      }
    } on Object {
      if (!mounted) {
        return;
      }
      setState(() {
        _busyRecipeId = '';
        _events[recipeId] = const ['failed'];
      });
    }
  }

  Future<void> _install(AgentHubRecipe recipe) async {
    if (_resolving.contains(recipe.id) ||
        !recipe.installable ||
        recipe.present) {
      return;
    }
    final selection = await showAgentHubInstallFlow(context, recipe: recipe);
    if (selection == null || !mounted) {
      return;
    }
    setState(() => _busyRecipeId = recipe.id);
    try {
      final planned = await widget.engine.plan(
        AgentHubPlanRequest(
          recipeId: recipe.id,
          channelId: selection.channelId,
          version: selection.version,
        ),
      );
      if (!planned.ok) {
        if (!mounted) {
          return;
        }
        setState(() {
          _busyRecipeId = '';
          _events[recipe.id] = planned.events.isEmpty
              ? const ['failed']
              : planned.events;
        });
        return;
      }
      final confirmed = await widget.engine.confirm(
        AgentHubConfirmRequest(recipeId: recipe.id),
      );
      if (!confirmed.ok) {
        if (!mounted) {
          return;
        }
        setState(() {
          _busyRecipeId = '';
          _events[recipe.id] = confirmed.events.isEmpty
              ? const ['failed']
              : confirmed.events;
        });
        return;
      }
      await _run(
        AgentHubLifecycleAction.install,
        recipeId: recipe.id,
        channelId: selection.channelId,
        version: selection.version,
      );
    } on Object {
      if (!mounted) {
        return;
      }
      setState(() {
        _busyRecipeId = '';
        _events[recipe.id] = const ['failed'];
      });
    }
  }

  Future<void> _uninstall(AgentHubRecipe recipe) async {
    if (_resolving.contains(recipe.id) || !recipe.showsManageActions) {
      return;
    }
    final confirmed = await showAgentHubUninstallConfirm(
      context,
      displayName: recipe.displayName,
    );
    if (!confirmed || !mounted) {
      return;
    }
    await _run(AgentHubLifecycleAction.uninstall, recipeId: recipe.id);
  }

  Future<void> _visit(AgentHubRecipe recipe) async {
    final uri = recipe.officialHomepage;
    final opener = widget.openHomepage;
    if (uri == null || opener == null) {
      setState(() => _visitFailed.add(recipe.id));
      return;
    }
    final opened = await opener(uri);
    if (!mounted) {
      return;
    }
    setState(() {
      if (opened) {
        _visitFailed.remove(recipe.id);
      } else {
        _visitFailed.add(recipe.id);
      }
    });
  }

  void _openAgent(AgentHubRecipe recipe) {
    if (_resolving.contains(recipe.id) || !recipe.present) {
      return;
    }
    widget.onOpenAgent?.call(recipe.id);
  }

  _HubCardActions _actionsFor(AgentHubRecipe recipe, bool resolving) {
    final busy = _busyRecipeId == recipe.id;
    final locked = resolving || busy;
    return _HubCardActions(
      installEnabled: !locked && recipe.installable && !recipe.present,
      updateEnabled: !locked && recipe.present && recipe.updateAvailable,
      openEnabled: !locked && recipe.present,
      uninstallEnabled: !locked && recipe.showsManageActions,
    );
  }

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final ordinaryDeclared = AgentHubLifecycleAction.values.every(
      (action) => AgentHubRuntimePlatform.values.every(
        (platform) =>
            widget.capabilities.supports(platform: platform, action: action),
      ),
    );
    if (!ordinaryDeclared) {
      throw const FormatException('agent_hub_ordinary_capability_incomplete');
    }
    final detail = _detailRecipe;
    Widget body;
    if (_loading && _recipes.isEmpty) {
      body = const Center(
        key: Key('agent-hub-loading'),
        child: CircularProgressIndicator(),
      );
    } else if (_catalogFailed && _recipes.isEmpty) {
      body = Center(
        key: const Key('agent-hub-catalog-failed'),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(strings.agentHubCatalogFailed),
            TextButton(
              onPressed: () => _loadCatalog(),
              child: Text(strings.agentHubRefresh),
            ),
          ],
        ),
      );
    } else if (detail != null) {
      final resolving = _resolving.contains(detail.id);
      body = _AgentHubDetailCard(
        recipe: detail,
        adaptationLabel: detail.adaptation == AgentHubAdaptationDepth.deep
            ? strings.adaptationDeep
            : strings.adaptationPartial,
        busy: _busyRecipeId == detail.id,
        loading: resolving,
        visitFailed: _visitFailed.contains(detail.id),
        events: _events[detail.id] ?? const [],
        visitLabel: strings.agentHubVisitOfficial,
        visitFailedLabel: strings.agentHubVisitFailed,
        installLabel: strings.install,
        updateLabel: strings.agentHubUpdate,
        openLabel: strings.agentHubOpen,
        uninstallLabel: strings.agentHubUninstall,
        actions: _actionsFor(detail, resolving),
        onInstall: () => _install(detail),
        onUpdate: () =>
            _run(AgentHubLifecycleAction.update, recipeId: detail.id),
        onOpen: () => _openAgent(detail),
        onUninstall: () => _uninstall(detail),
        onVisit: () => _visit(detail),
      );
    } else {
      body = CustomScrollView(
        slivers: [
          SliverGrid(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 340,
              mainAxisExtent: _hubCardExtent,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
            ),
            delegate: SliverChildBuilderDelegate((context, index) {
              final recipe = _recipes[index];
              final resolving = _resolving.contains(recipe.id);
              return _AgentHubRecipeCard(
                recipe: recipe,
                busy: _busyRecipeId == recipe.id,
                loading: resolving,
                events: _events[recipe.id] ?? const [],
                installLabel: strings.install,
                updateLabel: strings.agentHubUpdate,
                openLabel: strings.agentHubOpen,
                actions: _actionsFor(recipe, resolving),
                onOpenDetail: () => setState(() => _detailRecipeId = recipe.id),
                onInstall: () => _install(recipe),
                onUpdate: () =>
                    _run(AgentHubLifecycleAction.update, recipeId: recipe.id),
                onOpen: () => _openAgent(recipe),
              );
            }, childCount: _recipes.length),
          ),
        ],
      );
    }
    return LicoPaneScaffold(
      key: const Key('agent-hub-panel'),
      titleBarKey: const Key('agent-hub-top-bar'),
      title: detail?.displayName ?? strings.agentHub,
      refreshTooltip: strings.agentHubRefresh,
      onRefresh: _loadCatalog,
      refreshing: _discovering,
      refreshButtonKey: const Key('agent-hub-refresh'),
      refreshingIconKey: const Key('agent-hub-catalog-refresh'),
      leading: detail == null
          ? null
          : LicoIconButton(
              key: const Key('agent-hub-back'),
              tooltip: strings.agentHubBack,
              onPressed: () => setState(() => _detailRecipeId = null),
              icon: const Icon(Icons.arrow_back),
            ),
      body: body,
    );
  }
}

final class _HubCardActions {
  const _HubCardActions({
    required this.installEnabled,
    required this.updateEnabled,
    required this.openEnabled,
    required this.uninstallEnabled,
  });

  final bool installEnabled;
  final bool updateEnabled;
  final bool openEnabled;
  final bool uninstallEnabled;
}

TargetCandidate _brandTarget(AgentHubRecipe recipe) {
  return TargetCandidate(
    target: recipe.id,
    label: recipe.displayName,
    kind: 'cli',
    status: recipe.present ? 'detected' : 'not-detected',
    configured: recipe.present,
    confidence: 1,
    adapterStatus: 'implemented',
  );
}

final class _AgentHubRecipeCard extends StatelessWidget {
  const _AgentHubRecipeCard({
    required this.recipe,
    required this.busy,
    required this.loading,
    required this.events,
    required this.installLabel,
    required this.updateLabel,
    required this.openLabel,
    required this.actions,
    required this.onOpenDetail,
    required this.onInstall,
    required this.onUpdate,
    required this.onOpen,
  });

  final AgentHubRecipe recipe;
  final bool busy;
  final bool loading;
  final List<String> events;
  final String installLabel;
  final String updateLabel;
  final String openLabel;
  final _HubCardActions actions;
  final VoidCallback onOpenDetail;
  final VoidCallback onInstall;
  final VoidCallback onUpdate;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final textTheme = Theme.of(context).textTheme;
    return Card(
      key: Key('agent-hub-card-${recipe.id}'),
      clipBehavior: Clip.antiAlias,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(
          MessagingDesktopMetrics.conversationListCardCornerRadius,
        ),
        side: BorderSide(
          color: colors.line,
          width: MessagingDesktopMetrics.hairline,
        ),
      ),
      child: LicoShimmerMask(
        key: loading ? Key('agent-hub-card-loading-${recipe.id}') : null,
        enabled: loading,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  key: Key('agent-hub-intro-${recipe.id}'),
                  onTap: onOpenDetail,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                      _hubCardHorizontalInset,
                      _hubCardInset,
                      _hubCardHorizontalInset,
                      LicoContentSpacing.compact,
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        AgentBrandIcon(
                          target: _brandTarget(recipe),
                          size: _hubListIconSize,
                          iconSize: 20,
                        ),
                        const SizedBox(width: LicoContentSpacing.compact),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                recipe.displayName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: textTheme.titleSmall?.copyWith(
                                  color: colors.text,
                                ),
                              ),
                              const SizedBox(height: LicoContentSpacing.inline),
                              Expanded(
                                child: Text(
                                  recipe.summary,
                                  key: Key('agent-hub-summary-${recipe.id}'),
                                  maxLines: _hubListSummaryMaxLines,
                                  overflow: TextOverflow.ellipsis,
                                  style: textTheme.bodySmall?.copyWith(
                                    color: colors.textMuted,
                                    fontSize: _hubListSummaryFontSize,
                                    height: _hubListSummaryLineHeight,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            if (events.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  _hubCardHorizontalInset,
                  0,
                  _hubCardHorizontalInset,
                  LicoContentSpacing.inline,
                ),
                child: Text(
                  events.join(' · '),
                  key: Key('agent-hub-events-${recipe.id}'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.labelSmall?.copyWith(
                    color: colors.textMuted,
                  ),
                ),
              ),
            if (busy)
              const Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: _hubCardHorizontalInset,
                ),
                child: LinearProgressIndicator(
                  key: Key('agent-hub-card-busy'),
                  minHeight: 2,
                ),
              ),
            Divider(
              height: 1,
              thickness: MessagingDesktopMetrics.hairline,
              color: colors.line,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                _hubCardHorizontalInset,
                LicoContentSpacing.compact,
                _hubCardHorizontalInset,
                _hubCardInset,
              ),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _HubLifecycleAction(
                      actionKey: Key('agent-hub-install-${recipe.id}'),
                      icon: Icons.download_outlined,
                      label: installLabel,
                      enabled: actions.installEnabled,
                      kind: _HubLifecycleKind.filled,
                      onPressed: onInstall,
                    ),
                    const SizedBox(width: _hubFooterActionGap),
                    _HubLifecycleAction(
                      actionKey: Key('agent-hub-update-${recipe.id}'),
                      icon: Icons.system_update_alt_outlined,
                      label: updateLabel,
                      enabled: actions.updateEnabled,
                      kind: _HubLifecycleKind.filled,
                      onPressed: onUpdate,
                    ),
                    const SizedBox(width: _hubFooterActionGap),
                    _HubLifecycleAction(
                      actionKey: Key('agent-hub-open-${recipe.id}'),
                      icon: Icons.chat_bubble_outline,
                      label: openLabel,
                      enabled: actions.openEnabled,
                      kind: _HubLifecycleKind.filled,
                      onPressed: onOpen,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

final class _AgentHubDetailCard extends StatelessWidget {
  const _AgentHubDetailCard({
    required this.recipe,
    required this.adaptationLabel,
    required this.busy,
    required this.loading,
    required this.visitFailed,
    required this.events,
    required this.visitLabel,
    required this.visitFailedLabel,
    required this.installLabel,
    required this.updateLabel,
    required this.openLabel,
    required this.uninstallLabel,
    required this.actions,
    required this.onInstall,
    required this.onUpdate,
    required this.onOpen,
    required this.onUninstall,
    required this.onVisit,
  });

  final AgentHubRecipe recipe;
  final String adaptationLabel;
  final bool busy;
  final bool loading;
  final bool visitFailed;
  final List<String> events;
  final String visitLabel;
  final String visitFailedLabel;
  final String installLabel;
  final String updateLabel;
  final String openLabel;
  final String uninstallLabel;
  final _HubCardActions actions;
  final VoidCallback onInstall;
  final VoidCallback onUpdate;
  final VoidCallback onOpen;
  final VoidCallback onUninstall;
  final VoidCallback onVisit;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final textTheme = Theme.of(context).textTheme;
    final deep = recipe.adaptation == AgentHubAdaptationDepth.deep;
    final tagColor = deep ? colors.success : colors.warning;
    final homepage = recipe.officialHomepage;
    final visitEnabled = !busy && !loading && homepage != null && !visitFailed;
    return Align(
      alignment: Alignment.topLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Card(
          key: Key('agent-hub-detail-${recipe.id}'),
          clipBehavior: Clip.antiAlias,
          elevation: 0,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(
              MessagingDesktopMetrics.conversationListCardCornerRadius,
            ),
            side: BorderSide(
              color: colors.line,
              width: MessagingDesktopMetrics.hairline,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              _hubCardHorizontalInset,
              _hubCardInset,
              _hubCardHorizontalInset,
              _hubCardInset,
            ),
            child: LicoShimmerMask(
              key: loading ? Key('agent-hub-card-loading-${recipe.id}') : null,
              enabled: loading,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      AgentBrandIcon(
                        target: _brandTarget(recipe),
                        size: 48,
                        iconSize: 24,
                      ),
                      const SizedBox(width: LicoContentSpacing.item),
                      Expanded(
                        child: Text(
                          recipe.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.titleMedium?.copyWith(
                            color: colors.text,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      Container(
                        key: Key('agent-hub-adaptation-${recipe.id}'),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: tagColor.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(LicoRadius.chip),
                        ),
                        child: Text(
                          adaptationLabel,
                          style: textTheme.labelSmall?.copyWith(
                            color: tagColor,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: LicoContentSpacing.item),
                  AgentHubSummaryVisit(
                    summaryKey: Key('agent-hub-summary-${recipe.id}'),
                    visitKey: Key('agent-hub-visit-${recipe.id}'),
                    summary: recipe.summary,
                    visitLabel: visitLabel,
                    visitFailedLabel: visitFailedLabel,
                    visitFailed: visitFailed,
                    visitEnabled: visitEnabled,
                    onVisit: onVisit,
                  ),
                  const SizedBox(height: LicoContentSpacing.compact),
                  Row(
                    key: Key('agent-hub-channel-version-${recipe.id}'),
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      if (recipe.channelChipLabel.isNotEmpty)
                        Container(
                          key: Key('agent-hub-channel-${recipe.id}'),
                          padding: _hubChipPadding,
                          decoration: BoxDecoration(
                            color: colors.surfaceLow,
                            borderRadius: _hubChipBorderRadius,
                            border: Border.all(
                              color: colors.line,
                              width: MessagingDesktopMetrics.hairline,
                            ),
                          ),
                          child: Text(
                            recipe.channelChipLabel,
                            style: textTheme.labelSmall?.copyWith(
                              color: colors.textSecondary,
                              height: 1,
                            ),
                          ),
                        ),
                      if (recipe.versionLabel.isNotEmpty) ...[
                        if (recipe.channelChipLabel.isNotEmpty)
                          const SizedBox(width: LicoContentSpacing.compact),
                        Text(
                          recipe.versionLabel,
                          key: Key('agent-hub-version-${recipe.id}'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.labelSmall?.copyWith(
                            color: colors.textSecondary,
                            height: 1,
                          ),
                        ),
                      ],
                    ],
                  ),
                  if (events.isNotEmpty) ...[
                    const SizedBox(height: LicoContentSpacing.compact),
                    Text(
                      events.join(' · '),
                      key: Key('agent-hub-events-${recipe.id}'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.labelSmall?.copyWith(
                        color: colors.textMuted,
                      ),
                    ),
                  ],
                  if (busy)
                    const Padding(
                      padding: EdgeInsets.only(top: LicoContentSpacing.inline),
                      child: LinearProgressIndicator(
                        key: Key('agent-hub-card-busy'),
                        minHeight: 2,
                      ),
                    ),
                  const SizedBox(height: LicoContentSpacing.item),
                  Divider(
                    height: 1,
                    thickness: MessagingDesktopMetrics.hairline,
                    color: colors.line,
                  ),
                  const SizedBox(height: LicoContentSpacing.compact),
                  Wrap(
                    spacing: _hubFooterActionGap,
                    runSpacing: _hubFooterActionGap,
                    children: [
                      _HubLifecycleAction(
                        actionKey: Key('agent-hub-install-${recipe.id}'),
                        icon: Icons.download_outlined,
                        label: installLabel,
                        enabled: actions.installEnabled,
                        kind: _HubLifecycleKind.filled,
                        onPressed: onInstall,
                      ),
                      _HubLifecycleAction(
                        actionKey: Key('agent-hub-update-${recipe.id}'),
                        icon: Icons.system_update_alt_outlined,
                        label: updateLabel,
                        enabled: actions.updateEnabled,
                        kind: _HubLifecycleKind.filled,
                        onPressed: onUpdate,
                      ),
                      _HubLifecycleAction(
                        actionKey: Key('agent-hub-open-${recipe.id}'),
                        icon: Icons.chat_bubble_outline,
                        label: openLabel,
                        enabled: actions.openEnabled,
                        kind: _HubLifecycleKind.filled,
                        onPressed: onOpen,
                      ),
                      _HubLifecycleAction(
                        actionKey: Key('agent-hub-uninstall-${recipe.id}'),
                        icon: Icons.delete_outline,
                        label: uninstallLabel,
                        enabled: actions.uninstallEnabled,
                        kind: _HubLifecycleKind.danger,
                        onPressed: onUninstall,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

enum _HubLifecycleKind { filled, danger }

final class _HubLifecycleAction extends StatelessWidget {
  const _HubLifecycleAction({
    required this.actionKey,
    required this.icon,
    required this.label,
    required this.enabled,
    required this.kind,
    required this.onPressed,
  });

  final Key actionKey;
  final IconData icon;
  final String label;
  final bool enabled;
  final _HubLifecycleKind kind;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final textTheme = Theme.of(context).textTheme;
    final filled = kind == _HubLifecycleKind.filled;
    final Color foreground;
    final Color background;
    final Color borderColor;
    if (!enabled) {
      foreground = colors.textDisabled;
      background = filled
          ? colors.surfaceLow.withValues(alpha: 0.5)
          : Colors.transparent;
      borderColor = colors.line.withValues(alpha: 0.5);
    } else if (kind == _HubLifecycleKind.danger) {
      foreground = colors.error;
      background = Colors.transparent;
      borderColor = colors.error.withAlpha(120);
    } else {
      foreground = colors.textSecondary;
      background = colors.surfaceLow;
      borderColor = colors.line;
    }
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: actionKey,
        onTap: enabled ? onPressed : null,
        borderRadius: _hubChipBorderRadius,
        child: Ink(
          decoration: BoxDecoration(
            color: background,
            borderRadius: _hubChipBorderRadius,
            border: Border.all(
              color: borderColor,
              width: MessagingDesktopMetrics.hairline,
            ),
          ),
          child: Padding(
            padding: _hubChipPadding,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: _hubChipIconSize, color: foreground),
                const SizedBox(width: LicoContentSpacing.inline),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.labelSmall?.copyWith(
                    fontSize: _hubFooterActionFontSize,
                    height: 1,
                    fontWeight: FontWeight.w600,
                    color: foreground,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
