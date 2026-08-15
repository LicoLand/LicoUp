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
import 'package:licoup/src/frontend/shared/ui/lico_pane_scaffold.dart';
import 'package:licoup/src/frontend/shared/ui/lico_radius.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

const double _hubCardInset = LicoContentSpacing.compact;
const double _hubCardHorizontalInset = LicoContentSpacing.item;
const double _hubCardHeaderExtent = 28;
const double _hubCardFooterExtent = 24;
const double _hubCardExtent =
    _hubCardInset * 2 +
    _hubCardHeaderExtent +
    LicoContentSpacing.compact +
    AgentHubSummaryVisit.reservedHeight +
    LicoContentSpacing.compact +
    _hubCardFooterExtent +
    8;
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

/// Agent Hub body: native catalog cards with plan/confirm/install/verify/rescan.
final class AgentHubPanel extends StatefulWidget {
  const AgentHubPanel({
    super.key,
    this.engine = const UnwiredAgentHubEngine(),
    this.capabilities = const StaticAgentHubCapabilityPort(),
    this.openHomepage,
    this.orderRecipes = shuffleAgentHubRecipes,
  });

  final AgentHubEnginePort engine;
  final AgentHubCapabilityPort capabilities;
  final AgentHubHomepageOpener? openHomepage;
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
  int _loadGeneration = 0;
  final Set<String> _resolving = {};
  final Map<String, List<String>> _events = {};
  final Set<String> _visitFailed = {};

  bool get _discovering => _resolving.isNotEmpty;

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
    if (_resolving.contains(recipe.id) || !recipe.installable) {
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
              final cardBusy = _busyRecipeId == recipe.id;
              final resolving = _resolving.contains(recipe.id);
              final events = _events[recipe.id] ?? const [];
              return _AgentHubRecipeCard(
                recipe: recipe,
                adaptationLabel:
                    recipe.adaptation == AgentHubAdaptationDepth.deep
                    ? strings.adaptationDeep
                    : strings.adaptationPartial,
                busy: cardBusy,
                loading: resolving,
                visitFailed: _visitFailed.contains(recipe.id),
                events: events,
                visitLabel: strings.agentHubVisitOfficial,
                visitFailedLabel: strings.agentHubVisitFailed,
                installLabel: strings.install,
                updateLabel: strings.agentHubUpdate,
                uninstallLabel: strings.agentHubUninstall,
                onInstall: () => _install(recipe),
                onUpdate: () =>
                    _run(AgentHubLifecycleAction.update, recipeId: recipe.id),
                onUninstall: () => _uninstall(recipe),
                onVisit: () => _visit(recipe),
              );
            }, childCount: _recipes.length),
          ),
        ],
      );
    }
    return LicoPaneScaffold(
      key: const Key('agent-hub-panel'),
      titleBarKey: const Key('agent-hub-top-bar'),
      title: strings.agentHub,
      refreshTooltip: strings.agentHubRefresh,
      onRefresh: _loadCatalog,
      refreshing: _discovering,
      refreshButtonKey: const Key('agent-hub-refresh'),
      refreshingIconKey: const Key('agent-hub-catalog-refresh'),
      body: body,
    );
  }
}

final class _AgentHubRecipeCard extends StatelessWidget {
  const _AgentHubRecipeCard({
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
    required this.uninstallLabel,
    required this.onInstall,
    required this.onUpdate,
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
  final String uninstallLabel;
  final VoidCallback onInstall;
  final VoidCallback onUpdate;
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
    final manage = recipe.showsManageActions;
    final installEnabled = !loading && !busy && recipe.installable && !manage;
    final uninstallEnabled = !loading && !busy && manage;
    final updateEnabled = !loading && !busy && manage && recipe.updateAvailable;
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
            children: [
              Row(
                children: [
                  AgentBrandIcon(
                    target: TargetCandidate(
                      target: recipe.id,
                      label: recipe.displayName,
                      kind: 'cli',
                      status: recipe.present ? 'detected' : 'not-detected',
                      configured: recipe.present,
                      confidence: 1,
                      adapterStatus: 'implemented',
                    ),
                    size: 28,
                    iconSize: 16,
                  ),
                  const SizedBox(width: LicoContentSpacing.compact),
                  Expanded(
                    child: Text(
                      recipe.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.titleSmall?.copyWith(color: colors.text),
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
              const SizedBox(height: LicoContentSpacing.compact),
              Expanded(
                child: AgentHubSummaryVisit(
                  summaryKey: Key('agent-hub-summary-${recipe.id}'),
                  visitKey: Key('agent-hub-visit-${recipe.id}'),
                  summary: recipe.summary,
                  visitLabel: visitLabel,
                  visitFailedLabel: visitFailedLabel,
                  visitFailed: visitFailed,
                  visitEnabled: visitEnabled,
                  onVisit: onVisit,
                ),
              ),
              if (events.isNotEmpty)
                Text(
                  events.join(' · '),
                  key: Key('agent-hub-events-${recipe.id}'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.labelSmall?.copyWith(
                    color: colors.textMuted,
                  ),
                ),
              if (busy)
                const Padding(
                  padding: EdgeInsets.only(top: LicoContentSpacing.inline),
                  child: LinearProgressIndicator(
                    key: Key('agent-hub-card-busy'),
                    minHeight: 2,
                  ),
                ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Row(
                    key: Key('agent-hub-channel-version-${recipe.id}'),
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
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
                  const SizedBox(width: LicoContentSpacing.compact),
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerRight,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (manage) ...[
                              _HubLifecycleAction(
                                actionKey: Key('agent-hub-update-${recipe.id}'),
                                icon: Icons.system_update_alt_outlined,
                                label: updateLabel,
                                enabled: updateEnabled,
                                kind: _HubLifecycleKind.filled,
                                onPressed: onUpdate,
                              ),
                              const SizedBox(width: _hubFooterActionGap),
                              _HubLifecycleAction(
                                actionKey: Key(
                                  'agent-hub-uninstall-${recipe.id}',
                                ),
                                icon: Icons.delete_outline,
                                label: uninstallLabel,
                                enabled: uninstallEnabled,
                                kind: _HubLifecycleKind.danger,
                                onPressed: onUninstall,
                              ),
                            ] else
                              _HubLifecycleAction(
                                actionKey: Key(
                                  'agent-hub-install-${recipe.id}',
                                ),
                                icon: Icons.download_outlined,
                                label: installLabel,
                                enabled: installEnabled,
                                kind: _HubLifecycleKind.filled,
                                onPressed: onInstall,
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
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
