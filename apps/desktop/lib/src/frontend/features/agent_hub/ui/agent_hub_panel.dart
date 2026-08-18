import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:licoup/src/application/features/agent_hub/agent_hub_capability_port.dart';
import 'package:licoup/src/application/features/agent_hub/agent_hub_catalog_controller.dart';
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
const double _hubListEdgeInset = LicoContentSpacing.compact;
const double _hubListSummaryHorizontalInset =
    LicoContentSpacing.compact + LicoContentSpacing.inline;
const double _hubCardMaxWidth = 200;
const double _hubListIconSize = 44;
const double _hubListIconGlyphSize = 24;
const double _hubListIconNameGap =
    LicoContentSpacing.compact + LicoContentSpacing.inline;
const int _hubListNameMaxLines = 2;
const double _hubListNameLineHeight = 1.2;
const double _hubListSummaryFontSize = 12;
const double _hubListSummaryLineHeight = 1.4;
const int _hubListSummaryMaxLines = 3;
const double _hubListSummaryHeight =
    _hubListSummaryFontSize *
    _hubListSummaryLineHeight *
    _hubListSummaryMaxLines;
const double _hubTitleToSummaryGap = 0;
const double _hubSummaryToDividerGap = LicoContentSpacing.compact;
const double _hubCardFooterExtent = 36;
const double _hubCardExtent =
    _hubCardInset +
    _hubListIconSize +
    _hubTitleToSummaryGap +
    _hubListSummaryHeight +
    _hubSummaryToDividerGap +
    1 +
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
    required this.controller,
    this.capabilities = const StaticAgentHubCapabilityPort(),
    this.openHomepage,
    this.onOpenAgent,
    this.orderRecipes = shuffleAgentHubRecipes,
  });

  final AgentHubCatalogController controller;
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
    return controller.runLifecycle(
      action,
      recipeId: recipeId,
      channelId: channelId,
      version: version,
    );
  }

  @override
  State<AgentHubPanel> createState() => _AgentHubPanelState();
}

final class _AgentHubPanelState extends State<AgentHubPanel> {
  List<AgentHubRecipe> _recipes = const [];
  final Set<String> _orderedIds = {};
  bool _loading = true;
  bool _catalogFailed = false;
  String _busyRecipeId = '';
  String? _detailRecipeId;
  final Map<String, List<String>> _events = {};
  final Set<String> _visitFailed = {};

  bool get _discovering =>
      widget.controller.busy || widget.controller.resolving;

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
    widget.controller.addListener(_handleControllerChanged);
    _applyControllerProjection();
  }

  @override
  void didUpdateWidget(covariant AgentHubPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_handleControllerChanged);
      widget.controller.addListener(_handleControllerChanged);
      _applyControllerProjection();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleControllerChanged);
    super.dispose();
  }

  void _handleControllerChanged() {
    if (!mounted) return;
    setState(_applyControllerProjection);
  }

  /// Mirrors the application-owned projection without issuing any request.
  /// Mounting and remounting stay free of catalog I/O; completion of an
  /// entry or explicit refresh updates the visible cards through the listener.
  void _applyControllerProjection() {
    final snapshot = widget.controller.catalog;
    _loading =
        widget.controller.busy &&
            (snapshot == null || snapshot.recipes.isEmpty) ||
        (snapshot == null && !widget.controller.failed);
    _catalogFailed =
        widget.controller.failed &&
        (snapshot == null || snapshot.recipes.isEmpty);
    if (snapshot != null && snapshot.recipes.isNotEmpty) {
      _applyCache(snapshot);
    }
  }

  /// Shuffles once per new root snapshot; incremental recipe updates merge
  /// into the established order instead of reordering existing cards.
  List<AgentHubRecipe> _orderCatalog(List<AgentHubRecipe> incoming) {
    final sameIds =
        _orderedIds.length == incoming.length &&
        incoming.every((recipe) => _orderedIds.contains(recipe.id));
    var replaced = 0;
    if (sameIds) {
      final currentById = {for (final recipe in _recipes) recipe.id: recipe};
      for (final recipe in incoming) {
        if (!identical(currentById[recipe.id], recipe)) {
          replaced++;
        }
      }
    }
    if (!sameIds || replaced > 1) {
      final ordered = List<AgentHubRecipe>.from(widget.orderRecipes(incoming));
      _orderedIds
        ..clear()
        ..addAll(incoming.map((recipe) => recipe.id));
      return ordered;
    }
    final byId = {for (final recipe in incoming) recipe.id: recipe};
    return [for (final recipe in _recipes) byId[recipe.id] ?? recipe];
  }

  void _applyCache(AgentHubCatalogSnapshot? snapshot) {
    if (snapshot == null || snapshot.recipes.isEmpty) {
      return;
    }
    _recipes = _orderCatalog(snapshot.recipes);
    _loading = false;
    _catalogFailed = false;
  }

  /// Explicit refresh stays intentional and single-flight through the
  /// application controller; it is never part of panel mounting.
  Future<void> _loadCatalog() async {
    try {
      final snapshot = await widget.controller.refresh();
      if (!mounted) {
        return;
      }
      if (snapshot.ok || snapshot.recipes.isNotEmpty) {
        final ordered = _orderCatalog(snapshot.recipes);
        setState(() {
          _recipes = ordered;
          _catalogFailed = false;
          _loading = false;
          _busyRecipeId = '';
          _visitFailed.clear();
          if (_detailRecipeId != null &&
              ordered.every((recipe) => recipe.id != _detailRecipeId)) {
            _detailRecipeId = null;
          }
        });
        return;
      }
      setState(() {
        _catalogFailed = _recipes.isEmpty;
        _loading = false;
        _busyRecipeId = '';
      });
    } on Object {
      if (!mounted) {
        return;
      }
      setState(() {
        _catalogFailed = _recipes.isEmpty;
        _loading = false;
        _busyRecipeId = '';
      });
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
        await widget.controller.refreshRecipe(recipeId);
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
    if (widget.controller.isRecipeResolving(recipe.id) ||
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
      final planned = await widget.controller.runLifecycle(
        AgentHubLifecycleAction.plan,
        recipeId: recipe.id,
        channelId: selection.channelId,
        version: selection.version,
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
      final confirmed = await widget.controller.runLifecycle(
        AgentHubLifecycleAction.confirm,
        recipeId: recipe.id,
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
    if (widget.controller.isRecipeResolving(recipe.id) ||
        !recipe.showsManageActions) {
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
    if (widget.controller.isRecipeResolving(recipe.id) || !recipe.present) {
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
      final resolving = widget.controller.isRecipeResolving(detail.id);
      body = _AgentHubDetailCard(
        recipe: detail,
        adaptationLabel: switch (detail.adaptation) {
          AgentHubAdaptationDepth.deep => strings.adaptationDeep,
          AgentHubAdaptationDepth.partial => strings.adaptationPartial,
          AgentHubAdaptationDepth.pendingEvaluation =>
            strings.adaptationPending,
        },
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
              maxCrossAxisExtent: _hubCardMaxWidth,
              mainAxisExtent: _hubCardExtent,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
            ),
            delegate: SliverChildBuilderDelegate((context, index) {
              final recipe = _recipes[index];
              final resolving = widget.controller.isRecipeResolving(recipe.id);
              return _AgentHubRecipeCard(
                recipe: recipe,
                busy: _busyRecipeId == recipe.id,
                loading: resolving,
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

enum _HubPrimaryKind { install, update, open }

_HubPrimaryKind _listPrimaryKind(AgentHubRecipe recipe) {
  if (recipe.present && recipe.updateAvailable) {
    return _HubPrimaryKind.update;
  }
  if (recipe.present) {
    return _HubPrimaryKind.open;
  }
  return _HubPrimaryKind.install;
}

final class _HubListPrimaryButton extends StatelessWidget {
  const _HubListPrimaryButton({
    required this.recipeId,
    required this.kind,
    required this.installLabel,
    required this.updateLabel,
    required this.openLabel,
    required this.actions,
    required this.onInstall,
    required this.onUpdate,
    required this.onOpen,
  });

  final String recipeId;
  final _HubPrimaryKind kind;
  final String installLabel;
  final String updateLabel;
  final String openLabel;
  final _HubCardActions actions;
  final VoidCallback onInstall;
  final VoidCallback onUpdate;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final textTheme = Theme.of(context).textTheme;
    final (:actionKey, :icon, :label, :enabled, :onPressed) = switch (kind) {
      _HubPrimaryKind.update => (
        actionKey: Key('agent-hub-update-$recipeId'),
        icon: Icons.system_update_alt_outlined,
        label: updateLabel,
        enabled: actions.updateEnabled,
        onPressed: onUpdate,
      ),
      _HubPrimaryKind.open => (
        actionKey: Key('agent-hub-open-$recipeId'),
        icon: Icons.chat_bubble_outline,
        label: openLabel,
        enabled: actions.openEnabled,
        onPressed: onOpen,
      ),
      _HubPrimaryKind.install => (
        actionKey: Key('agent-hub-install-$recipeId'),
        icon: Icons.download_outlined,
        label: installLabel,
        enabled: actions.installEnabled,
        onPressed: onInstall,
      ),
    };
    final foreground = enabled ? colors.textSecondary : colors.textDisabled;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: actionKey,
        onTap: enabled ? onPressed : null,
        child: SizedBox(
          height: _hubCardFooterExtent,
          width: double.infinity,
          child: Center(
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
            Material(
              color: Colors.transparent,
              child: InkWell(
                key: Key('agent-hub-intro-${recipe.id}'),
                onTap: onOpenDetail,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      key: Key('agent-hub-header-${recipe.id}'),
                      padding: const EdgeInsets.fromLTRB(
                        _hubListEdgeInset,
                        _hubCardInset,
                        _hubListEdgeInset,
                        0,
                      ),
                      child: SizedBox(
                        height: _hubListIconSize,
                        child: Row(
                          children: [
                            AgentBrandIcon(
                              target: _brandTarget(recipe),
                              size: _hubListIconSize,
                              iconSize: _hubListIconGlyphSize,
                            ),
                            const SizedBox(width: _hubListIconNameGap),
                            Expanded(
                              child: Text(
                                recipe.displayName,
                                key: Key('agent-hub-name-${recipe.id}'),
                                maxLines: _hubListNameMaxLines,
                                overflow: TextOverflow.ellipsis,
                                style: textTheme.titleSmall?.copyWith(
                                  color: colors.text,
                                  height: _hubListNameLineHeight,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: _hubTitleToSummaryGap),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: _hubListSummaryHorizontalInset,
                      ),
                      child: SizedBox(
                        height: _hubListSummaryHeight,
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
                    ),
                    const SizedBox(height: _hubSummaryToDividerGap),
                  ],
                ),
              ),
            ),
            SizedBox(
              height: 1,
              child: busy
                  ? const LinearProgressIndicator(
                      key: Key('agent-hub-card-busy'),
                      minHeight: 1,
                    )
                  : Divider(
                      height: 1,
                      thickness: MessagingDesktopMetrics.hairline,
                      color: colors.line,
                    ),
            ),
            _HubListPrimaryButton(
              recipeId: recipe.id,
              kind: _listPrimaryKind(recipe),
              installLabel: installLabel,
              updateLabel: updateLabel,
              openLabel: openLabel,
              actions: actions,
              onInstall: onInstall,
              onUpdate: onUpdate,
              onOpen: onOpen,
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
    final tagColor = switch (recipe.adaptation) {
      AgentHubAdaptationDepth.deep => colors.success,
      AgentHubAdaptationDepth.partial => colors.warning,
      AgentHubAdaptationDepth.pendingEvaluation => colors.textMuted,
    };
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
                          maxLines: 2,
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
