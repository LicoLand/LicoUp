import 'package:flutter/material.dart';

import 'package:licoup/src/application/features/agent_hub/agent_hub_capability_port.dart';
import 'package:licoup/src/application/features/agent_hub/agent_hub_engine.dart';
import 'package:licoup/src/contracts/agent_hub.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/tokens/messaging_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/ui/agent_brand_icon.dart';
import 'package:licoup/src/frontend/shared/ui/lico_content_spacing.dart';
import 'package:licoup/src/frontend/shared/ui/lico_radius.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

const double _hubFooterActionGap = LicoContentSpacing.item;
const double _hubFooterActionFontSize = 13;
const double _hubFooterActionVerticalPadding = 4;

/// Opens a warehouse-static official HTTPS homepage. Fail closed.
typedef AgentHubHomepageOpener = Future<bool> Function(Uri uri);

/// Agent Hub body: native catalog cards with plan/confirm/install/verify/rescan.
final class AgentHubPanel extends StatefulWidget {
  const AgentHubPanel({
    super.key,
    this.engine = const UnwiredAgentHubEngine(),
    this.capabilities = const StaticAgentHubCapabilityPort(),
    this.openHomepage,
  });

  final AgentHubEnginePort engine;
  final AgentHubCapabilityPort capabilities;
  final AgentHubHomepageOpener? openHomepage;

  Future<AgentHubOperationResult> runLifecycle(
    AgentHubLifecycleAction action, {
    required String recipeId,
  }) {
    return switch (action) {
      AgentHubLifecycleAction.plan => engine.plan(
        AgentHubPlanRequest(recipeId: recipeId),
      ),
      AgentHubLifecycleAction.confirm => engine.confirm(
        AgentHubConfirmRequest(recipeId: recipeId),
      ),
      AgentHubLifecycleAction.install => engine.install(
        AgentHubInstallRequest(recipeId: recipeId),
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
  final Set<String> _planned = {};
  final Set<String> _confirmed = {};
  final Map<String, List<String>> _events = {};
  final Set<String> _visitFailed = {};

  @override
  void initState() {
    super.initState();
    _loadCatalog();
  }

  @override
  void didUpdateWidget(covariant AgentHubPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.engine, widget.engine)) {
      _loadCatalog(indicate: true);
    }
  }

  Future<void> _loadCatalog({bool indicate = false}) async {
    if (indicate && mounted) {
      setState(() => _loading = true);
    }
    try {
      final snapshot = await widget.engine.catalog();
      if (!mounted) {
        return;
      }
      setState(() {
        if (snapshot.ok || snapshot.recipes.isNotEmpty) {
          _recipes = snapshot.recipes;
        }
        _catalogFailed = !snapshot.ok;
        _loading = false;
        _busyRecipeId = '';
        _visitFailed.clear();
      });
    } on Object {
      if (!mounted) {
        return;
      }
      setState(() {
        _catalogFailed = true;
        _loading = false;
        _busyRecipeId = '';
      });
    }
  }

  Future<void> _run(
    AgentHubLifecycleAction action, {
    required String recipeId,
  }) async {
    setState(() => _busyRecipeId = recipeId);
    try {
      final result = await widget.runLifecycle(action, recipeId: recipeId);
      if (!mounted) {
        return;
      }
      setState(() {
        _busyRecipeId = '';
        _events[recipeId] = result.events
            .where((phase) => phase != 'verifying' && phase != 'rescanning')
            .toList();
        if (result.recipes.isNotEmpty) {
          _recipes = result.recipes;
          _catalogFailed = false;
        }
        if (action == AgentHubLifecycleAction.plan &&
            result.status == AgentHubOperationStatus.completed) {
          _planned.add(recipeId);
          _confirmed.remove(recipeId);
        }
        if (action == AgentHubLifecycleAction.confirm && result.ok) {
          _confirmed.add(recipeId);
        }
        if ((action == AgentHubLifecycleAction.install ||
                action == AgentHubLifecycleAction.update ||
                action == AgentHubLifecycleAction.uninstall) &&
            result.ok) {
          _planned.remove(recipeId);
          _confirmed.remove(recipeId);
        }
      });
      if (result.recipes.isEmpty &&
          (action == AgentHubLifecycleAction.install ||
              action == AgentHubLifecycleAction.update ||
              action == AgentHubLifecycleAction.uninstall) &&
          result.ok) {
        await _loadCatalog();
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
    if (_loading && _recipes.isEmpty) {
      return const Center(
        key: Key('agent-hub-loading'),
        child: CircularProgressIndicator(),
      );
    }
    if (_catalogFailed && _recipes.isEmpty) {
      return Center(
        key: const Key('agent-hub-catalog-failed'),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(strings.agentHubCatalogFailed),
            TextButton(
              onPressed: () => _loadCatalog(indicate: true),
              child: Text(strings.rescan),
            ),
          ],
        ),
      );
    }
    return CustomScrollView(
      key: const Key('agent-hub-panel'),
      slivers: [
        if (_loading)
          const SliverToBoxAdapter(
            child: LinearProgressIndicator(
              key: Key('agent-hub-catalog-refresh'),
            ),
          ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(
            LicoContentSpacing.item,
            LicoContentSpacing.item,
            LicoContentSpacing.item,
            LicoContentSpacing.section,
          ),
          sliver: SliverGrid(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 340,
              mainAxisExtent: 208,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
            ),
            delegate: SliverChildBuilderDelegate((context, index) {
              final recipe = _recipes[index];
              final cardBusy = _busyRecipeId == recipe.id;
              final events = _events[recipe.id] ?? const [];
              return _AgentHubRecipeCard(
                recipe: recipe,
                adaptationLabel:
                    recipe.adaptation == AgentHubAdaptationDepth.deep
                    ? strings.adaptationDeep
                    : strings.adaptationPartial,
                busy: cardBusy,
                planned: _planned.contains(recipe.id),
                confirmed: _confirmed.contains(recipe.id),
                visitFailed: _visitFailed.contains(recipe.id),
                events: events,
                planLabel: strings.installPlan,
                confirmLabel: strings.apply,
                installLabel: strings.install,
                moreLabel: strings.moreActions,
                visitLabel: strings.agentHubVisit,
                visitFailedLabel: strings.agentHubVisitFailed,
                updateLabel: strings.agentHubUpdate,
                uninstallLabel: strings.agentHubUninstall,
                rescanLabel: strings.rescan,
                onPlan: () =>
                    _run(AgentHubLifecycleAction.plan, recipeId: recipe.id),
                onConfirm: () =>
                    _run(AgentHubLifecycleAction.confirm, recipeId: recipe.id),
                onInstall: () =>
                    _run(AgentHubLifecycleAction.install, recipeId: recipe.id),
                onRescan: () =>
                    _run(AgentHubLifecycleAction.rescan, recipeId: recipe.id),
                onUpdate: () =>
                    _run(AgentHubLifecycleAction.update, recipeId: recipe.id),
                onUninstall: () => _run(
                  AgentHubLifecycleAction.uninstall,
                  recipeId: recipe.id,
                ),
                onVisit: () => _visit(recipe),
              );
            }, childCount: _recipes.length),
          ),
        ),
      ],
    );
  }
}

final class _AgentHubRecipeCard extends StatelessWidget {
  const _AgentHubRecipeCard({
    required this.recipe,
    required this.adaptationLabel,
    required this.busy,
    required this.planned,
    required this.confirmed,
    required this.visitFailed,
    required this.events,
    required this.planLabel,
    required this.confirmLabel,
    required this.installLabel,
    required this.moreLabel,
    required this.visitLabel,
    required this.visitFailedLabel,
    required this.updateLabel,
    required this.uninstallLabel,
    required this.rescanLabel,
    required this.onPlan,
    required this.onConfirm,
    required this.onInstall,
    required this.onRescan,
    required this.onUpdate,
    required this.onUninstall,
    required this.onVisit,
  });

  final AgentHubRecipe recipe;
  final String adaptationLabel;
  final bool busy;
  final bool planned;
  final bool confirmed;
  final bool visitFailed;
  final List<String> events;
  final String planLabel;
  final String confirmLabel;
  final String installLabel;
  final String moreLabel;
  final String visitLabel;
  final String visitFailedLabel;
  final String updateLabel;
  final String uninstallLabel;
  final String rescanLabel;
  final VoidCallback onPlan;
  final VoidCallback onConfirm;
  final VoidCallback onInstall;
  final VoidCallback onRescan;
  final VoidCallback onUpdate;
  final VoidCallback onUninstall;
  final VoidCallback onVisit;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final textTheme = Theme.of(context).textTheme;
    final deep = recipe.adaptation == AgentHubAdaptationDepth.deep;
    final tagColor = deep ? colors.success : colors.warning;
    final external =
        recipe.ownership == 'external' ||
        recipe.ownership == 'external_protected';
    final homepage = recipe.officialHomepage;
    final visitEnabled = !busy && homepage != null && !visitFailed;
    final managed = recipe.ownership == 'owned';
    final manageEnabled = !busy && managed;
    return Card(
      key: Key('agent-hub-card-${recipe.id}'),
      clipBehavior: Clip.antiAlias,
      elevation: 0,
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
        padding: const EdgeInsets.all(LicoContentSpacing.compact),
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
                PopupMenuButton<AgentHubLifecycleAction>(
                  key: Key('agent-hub-more-${recipe.id}'),
                  tooltip: moreLabel,
                  enabled: !busy,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 24,
                    minHeight: 24,
                  ),
                  icon: Icon(
                    Icons.more_horiz,
                    size: 18,
                    color: colors.textMuted,
                  ),
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      key: Key('agent-hub-plan-${recipe.id}'),
                      value: AgentHubLifecycleAction.plan,
                      enabled: !external && recipe.installable,
                      child: Text(planLabel),
                    ),
                    PopupMenuItem(
                      key: Key('agent-hub-confirm-${recipe.id}'),
                      value: AgentHubLifecycleAction.confirm,
                      enabled: planned && !confirmed,
                      child: Text(confirmLabel),
                    ),
                    PopupMenuItem(
                      key: Key('agent-hub-install-${recipe.id}'),
                      value: AgentHubLifecycleAction.install,
                      enabled: confirmed,
                      child: Text(installLabel),
                    ),
                    PopupMenuItem(
                      key: Key('agent-hub-rescan-${recipe.id}'),
                      value: AgentHubLifecycleAction.rescan,
                      child: Text(rescanLabel),
                    ),
                  ],
                  onSelected: (action) {
                    switch (action) {
                      case AgentHubLifecycleAction.plan:
                        onPlan();
                      case AgentHubLifecycleAction.confirm:
                        onConfirm();
                      case AgentHubLifecycleAction.install:
                        onInstall();
                      case AgentHubLifecycleAction.rescan:
                        onRescan();
                      case AgentHubLifecycleAction.update:
                      case AgentHubLifecycleAction.uninstall:
                      case AgentHubLifecycleAction.verify:
                        break;
                    }
                  },
                ),
              ],
            ),
            const SizedBox(height: LicoContentSpacing.compact),
            Text(
              recipe.summary,
              key: Key('agent-hub-summary-${recipe.id}'),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: textTheme.bodySmall?.copyWith(
                color: colors.textMuted,
                height: 1.4,
              ),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: InkWell(
                key: Key('agent-hub-visit-${recipe.id}'),
                onTap: visitEnabled ? onVisit : null,
                borderRadius: BorderRadius.circular(LicoRadius.chip),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(
                    visitFailed ? visitFailedLabel : visitLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.labelSmall?.copyWith(
                      color: visitFailed
                          ? colors.error
                          : visitEnabled
                          ? colors.accent
                          : colors.textDisabled,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
            const Spacer(),
            if (events.isNotEmpty)
              Text(
                events.join(' · '),
                key: Key('agent-hub-events-${recipe.id}'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textTheme.labelSmall?.copyWith(color: colors.textMuted),
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
                Container(
                  key: Key('agent-hub-channel-${recipe.id}'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: colors.surfaceLow,
                    borderRadius: BorderRadius.circular(LicoRadius.chip),
                    border: Border.all(
                      color: colors.line,
                      width: MessagingDesktopMetrics.hairline,
                    ),
                  ),
                  child: Text(
                    recipe.channelChipLabel,
                    style: textTheme.labelSmall?.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ),
                const SizedBox(width: LicoContentSpacing.compact),
                Expanded(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Flexible(
                        child: _HubTextAction(
                          actionKey: Key('agent-hub-update-${recipe.id}'),
                          label: updateLabel,
                          enabled: manageEnabled,
                          onPressed: onUpdate,
                        ),
                      ),
                      const SizedBox(width: _hubFooterActionGap),
                      Flexible(
                        child: _HubTextAction(
                          actionKey: Key('agent-hub-uninstall-${recipe.id}'),
                          label: uninstallLabel,
                          enabled: manageEnabled,
                          onPressed: onUninstall,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

final class _HubTextAction extends StatelessWidget {
  const _HubTextAction({
    required this.actionKey,
    required this.label,
    required this.enabled,
    required this.onPressed,
  });

  final Key actionKey;
  final String label;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final textTheme = Theme.of(context).textTheme;
    return InkWell(
      key: actionKey,
      onTap: enabled ? onPressed : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          vertical: _hubFooterActionVerticalPadding,
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: textTheme.labelSmall?.copyWith(
            fontSize: _hubFooterActionFontSize,
            height: 1.2,
            fontWeight: FontWeight.w600,
            color: enabled ? colors.accent : colors.textDisabled,
          ),
        ),
      ),
    );
  }
}
