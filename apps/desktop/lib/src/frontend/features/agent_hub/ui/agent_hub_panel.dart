import 'package:licoup/src/frontend/shared/ui/lico_loading_indicator.dart';
import 'package:licoup/src/frontend/shared/ui/lico_pane_card.dart';
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/binding/effect_listener.dart';
import 'package:licoup/src/frontend/binding/projection_builder.dart';
import 'package:licoup/src/frontend/features/agent_hub/ui/agent_hub_install_dialog.dart';
import 'package:licoup/src/frontend/features/agent_hub/ui/agent_hub_detail_tabs.dart';
import 'package:licoup/src/frontend/features/agent_hub/ui/agent_hub_uninstall_dialog.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/agent_brand_icon.dart';
import 'package:licoup/src/frontend/shared/ui/continuous_stroke.dart';
import 'package:licoup/src/frontend/shared/ui/lico_activity_animations.dart';
import 'package:licoup/src/frontend/shared/ui/lico_content_spacing.dart';
import 'package:licoup/src/frontend/shared/ui/lico_icon_button.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';
import 'package:licoup/src/frontend/shared/ui/lico_pane_scaffold.dart';
import 'package:licoup/src/frontend/appearance/appearance_visuals.dart';
import 'package:licoup/src/frontend/shared/ui/lico_elevation.dart';
import 'package:licoup/src/frontend/shared/ui/lico_search_capsule.dart';
import 'package:licoup/src/frontend/shared/ui/lico_profile_card.dart';
import 'package:licoup/src/frontend/features/agent_hub/ui/agent_hub_surface.dart';
import 'package:licoup/src/frontend/features/plugin_management/ui/adapter_plugin_panel.dart';
import 'package:licoup/src/frontend/features/skill_hub/ui/skill_hub_panel.dart';
import 'package:licoup/src/presentation/plugin_management/plugin_management_binding.dart';
import 'package:licoup/src/presentation/plugin_management/plugin_management_intent.dart';
import 'package:licoup/src/presentation/plugin_management/plugin_management_projection.dart';
import 'package:licoup/src/presentation/skill_hub/skill_hub_binding.dart';
import 'package:licoup/src/presentation/skill_hub/skill_hub_intent.dart';
import 'package:licoup/src/presentation/skill_hub/skill_hub_projection.dart';
import 'package:licoup/src/frontend/shared/ui/messaging_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/agent_hub/agent_hub_binding.dart';
import 'package:licoup/src/presentation/agent_hub/agent_hub_effect.dart';
import 'package:licoup/src/presentation/agent_hub/agent_hub_intent.dart';
import 'package:licoup/src/presentation/agent_hub/agent_hub_projection.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';

const double _hubTileAvatarSize = 56;
const double _hubTileAvatarGlyphSize = 30;
const String _hubCardEntryKeyPrefix = 'agent-hub-card-entry-';
const double _hubTilePadding = 14;
const double _hubTileAvatarToNameGap = 10;
const double _hubTileNameToDescGap = 6;
const double _hubTileDescToStatusGap = 8;
const double _hubStatusDotSize = 7;
const double _hubTileStatusToActionGap = 10;

/// The design lab's split card: a rounded tile divided by a hairline into a
/// large intro section and a one-button-high footer strip.
const double _hubCardFooterExtent = 36;
const double _hubCardExtent =
    _hubTilePadding +
    _hubTileAvatarSize +
    _hubTileAvatarToNameGap +
    20 +
    _hubTileNameToDescGap +
    34 +
    _hubTileDescToStatusGap +
    18 +
    _hubTileStatusToActionGap +
    1 +
    _hubCardFooterExtent;
const double _hubGridGap = 12;
const double _hubTileMinWidth = 200;
const double _hubFooterActionFontSize = 12;
const double _hubChipIconSize = 13;

typedef AgentHubCatalogOrder =
    List<AgentHubEntryProjection> Function(
      List<AgentHubEntryProjection> recipes, [
      int? seed,
    ]);

List<AgentHubEntryProjection> shuffleAgentHubRecipes(
  List<AgentHubEntryProjection> recipes, [
  int? seed,
]) {
  final next = List<AgentHubEntryProjection>.from(recipes);
  next.shuffle(seed == null ? math.Random() : math.Random(seed));
  return next;
}

typedef AgentHubExternalOpener = Future<void> Function(Uri uri);
typedef AgentHubOpenAgent = ValueChanged<String>;

enum _AgentHubDetailDestination { overview, plugins, skills }

enum _AgentHubCatalogFilter { all, installed, missing }

/// Pure semantic Agent Hub renderer. All catalog state and lifecycle work enter
/// through [AgentHubBinding]; this widget owns only transient presentation state.
final class AgentHubPanel extends StatefulWidget {
  const AgentHubPanel({
    super.key,
    required this.binding,
    this.openHomepage,
    this.onOpenAgent,
    this.plugins,
    this.skills,
    this.orderEntries = shuffleAgentHubRecipes,
  });

  final AgentHubBinding binding;
  final AgentHubExternalOpener? openHomepage;
  final AgentHubOpenAgent? onOpenAgent;
  final PluginManagementBinding? plugins;
  final SkillHubBinding? skills;
  final AgentHubCatalogOrder orderEntries;

  @override
  State<AgentHubPanel> createState() => _AgentHubPanelState();
}

final class _AgentHubPanelState extends State<AgentHubPanel> {
  List<AgentHubEntryProjection> _entries = const [];
  final Set<String> _orderedIds = {};
  String _busyEntryId = '';
  String? _detailEntryId;
  _AgentHubDetailDestination _detailTab = _AgentHubDetailDestination.overview;
  String _catalogQuery = '';
  _AgentHubCatalogFilter _catalogFilter = _AgentHubCatalogFilter.all;
  final Map<String, List<String>> _events = {};
  final Set<String> _visitFailed = {};

  /// Live install status notifiers keyed by entry id, driving the install
  /// dialog's in-place progress state until the operation effect arrives.
  final Map<String, ValueNotifier<AgentHubInstallStatus>> _installStatuses = {};
  int _refreshRevision = -1;

  List<_AgentHubDetailDestination> get _detailDestinations => [
    _AgentHubDetailDestination.overview,
    if (widget.plugins != null) _AgentHubDetailDestination.plugins,
    if (widget.skills != null) _AgentHubDetailDestination.skills,
  ];

  AgentHubEntryProjection? get _detailEntry {
    final id = _detailEntryId;
    if (id == null) return null;
    return _entries.where((entry) => entry.id == id).firstOrNull;
  }

  static Key _cardEntryKey(String entryId) =>
      ValueKey<String>('$_hubCardEntryKeyPrefix$entryId');

  static int? _cardEntryIndex(List<AgentHubEntryProjection> entries, Key key) {
    if (key is! ValueKey<String> ||
        !key.value.startsWith(_hubCardEntryKeyPrefix)) {
      return null;
    }
    final id = key.value.substring(_hubCardEntryKeyPrefix.length);
    final index = entries.indexWhere((entry) => entry.id == id);
    return index < 0 ? null : index;
  }

  List<AgentHubEntryProjection> _orderedProjection(
    AgentHubProjection projection,
  ) {
    final incoming = projection.entries;
    final sameIds =
        _orderedIds.length == incoming.length &&
        incoming.every((entry) => _orderedIds.contains(entry.id));
    final refreshStarted = projection.refreshRevision != _refreshRevision;
    _refreshRevision = projection.refreshRevision;

    if (incoming.isEmpty) {
      _entries = const [];
      _orderedIds.clear();
      return _entries;
    }
    if (_entries.isEmpty || !sameIds || refreshStarted) {
      _entries = List<AgentHubEntryProjection>.from(
        widget.orderEntries(incoming, projection.refreshRevision),
      );
      _orderedIds
        ..clear()
        ..addAll(incoming.map((entry) => entry.id));
    } else {
      final byId = {for (final entry in incoming) entry.id: entry};
      _entries = [for (final entry in _entries) byId[entry.id] ?? entry];
    }
    if (_detailEntryId != null &&
        _entries.every((entry) => entry.id != _detailEntryId)) {
      _detailEntryId = null;
    }
    // The pinned order covers the full catalog, so a card settling into the
    // grid never reshuffles the ones already on screen. Only cards whose
    // inspection has settled are rendered; the rest stay out of the grid.
    return [
      for (final entry in _entries)
        if (!entry.pending) entry,
    ];
  }

  Future<void> _install(AgentHubEntryProjection entry) async {
    if (entry.busy || !entry.installable || entry.installed) return;
    final status = ValueNotifier<AgentHubInstallStatus>(
      AgentHubInstallStatus.running,
    );
    await showAgentHubInstallFlow(
      context,
      recipe: entry,
      installStatus: status,
      onInstall: (selection) {
        setState(() => _busyEntryId = entry.id);
        _installStatuses[entry.id] = status;
        widget.binding.intents.send(
          InstallAgentHubEntry(
            entry.id,
            channelId: selection.channelId,
            version: selection.version,
          ),
        );
      },
    );
    _installStatuses.remove(entry.id);
    status.dispose();
  }

  void _update(String entryId) {
    setState(() => _busyEntryId = entryId);
    widget.binding.intents.send(UpdateAgentHubEntry(entryId));
  }

  Future<void> _uninstall(AgentHubEntryProjection entry) async {
    if (entry.busy || !entry.showsManageActions) return;
    final confirmed = await showAgentHubUninstallConfirm(
      context,
      displayName: entry.displayName,
    );
    if (!confirmed || !mounted) return;
    setState(() => _busyEntryId = entry.id);
    widget.binding.intents.send(UninstallAgentHubEntry(entry.id));
  }

  void _openAgent(AgentHubEntryProjection entry) {
    if (entry.busy || !entry.present) return;
    widget.binding.intents.send(OpenAgentHubAgent(entry.id));
  }

  /// Re-runs one card's live inspection after it failed, without asking native
  /// for a machine-wide rescan.
  void _retryInspection(String entryId) {
    widget.binding.intents.send(RetryAgentHubEntry(entryId));
  }

  void _visit(AgentHubEntryProjection entry) {
    if (entry.officialHomepage == null) {
      setState(() => _visitFailed.add(entry.id));
      return;
    }
    widget.binding.intents.send(OpenAgentHubHomepage(entry.id));
  }

  void _openDetail(String entryId) {
    setState(() {
      _detailEntryId = entryId;
      _detailTab = _AgentHubDetailDestination.overview;
    });
    // Start both resources without making either one wait for its sibling.
    widget.plugins?.intents.send(const RefreshPlugins());
    widget.skills?.intents.send(const RefreshSkillHub());
  }

  _HubCardActions _actionsFor(AgentHubEntryProjection entry, bool resolving) {
    final locked =
        resolving || entry.resolutionFailed || _busyEntryId == entry.id;
    return _HubCardActions(
      installEnabled: !locked && entry.installable && !entry.present,
      updateEnabled: !locked && entry.present && entry.updateAvailable,
      openEnabled: !locked && entry.present,
      uninstallEnabled: !locked && entry.showsManageActions,
    );
  }

  void _handleEffect(AgentHubEffect effect) {
    switch (effect) {
      case AgentHubInstallPlanReady():
        break;
      case AgentHubExternalOpenRequested():
        unawaited(_openExternal(effect));
      case AgentHubAgentOpenRequested():
        widget.onOpenAgent?.call(effect.entryId);
      case AgentHubOperationCompleted():
        if (!mounted) return;
        _installStatuses[effect.entryId]?.value =
            AgentHubInstallStatus.succeeded;
        setState(() {
          _busyEntryId = '';
          _events[effect.entryId] = effect.events
              .where((event) => event != 'verifying' && event != 'rescanning')
              .toList(growable: false);
          if (effect.kind == AgentHubOperationEffectKind.uninstall) {
            _detailEntryId = null;
          }
        });
      case AgentHubActionRejected():
        if (!mounted) return;
        _installStatuses[effect.entryId]?.value = AgentHubInstallStatus.failed;
        setState(() {
          _busyEntryId = '';
          _events[effect.entryId] = const ['failed'];
        });
    }
  }

  Future<void> _openExternal(AgentHubExternalOpenRequested effect) async {
    final uri = Uri.tryParse(effect.uri);
    final opener = widget.openHomepage;
    if (uri == null ||
        uri.scheme.toLowerCase() != 'https' ||
        uri.host.isEmpty ||
        opener == null) {
      if (mounted) setState(() => _visitFailed.add(effect.entryId));
      return;
    }
    try {
      await opener(uri);
      if (mounted) setState(() => _visitFailed.remove(effect.entryId));
    } on Object {
      if (mounted) setState(() => _visitFailed.add(effect.entryId));
    }
  }

  @override
  Widget build(BuildContext context) {
    return EffectListener<AgentHubEffect>(
      source: widget.binding.effects,
      onEffect: _handleEffect,
      child: ProjectionBuilder<AgentHubProjection, AgentHubProjection>(
        source: widget.binding.projection,
        select: (projection) => projection,
        builder: (context, projection) => _buildProjection(projection),
      ),
    );
  }

  Widget _buildProjection(AgentHubProjection projection) {
    final entries = _orderedProjection(projection);
    final strings = LicoStrings.of(context);
    final detail = _detailEntry;
    final destinations = _detailDestinations;
    final selectedIndex = math.max(0, destinations.indexOf(_detailTab));
    final labels = [
      for (final destination in destinations)
        switch (destination) {
          _AgentHubDetailDestination.overview =>
            strings.isChinese ? '概览' : 'Overview',
          _AgentHubDetailDestination.plugins => strings.pluginsNav,
          _AgentHubDetailDestination.skills => strings.skillsNav,
        },
    ];
    // Cards enter the grid only as their own inspection settles, so an empty
    // grid while inspections are still in flight keeps the loading treatment.
    final settling = projection.entries.any((entry) => entry.pending);
    final catalogEntries = entries
        .where((entry) {
          switch (_catalogFilter) {
            case _AgentHubCatalogFilter.installed:
              if (!entry.present) return false;
            case _AgentHubCatalogFilter.missing:
              if (entry.present) return false;
            case _AgentHubCatalogFilter.all:
          }
          final query = _catalogQuery.trim().toLowerCase();
          return query.isEmpty ||
              entry.displayName.toLowerCase().contains(query) ||
              entry.summary.toLowerCase().contains(query);
        })
        .toList(growable: false);
    Widget body;
    if (projection.phase == PresentationPhase.failed && entries.isEmpty) {
      body = Center(
        key: const Key('agent-hub-catalog-failed'),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(strings.agentHubCatalogFailed),
            TextButton(
              onPressed: () =>
                  widget.binding.intents.send(const RefreshAgentHub()),
              child: Text(strings.agentHubRefresh),
            ),
          ],
        ),
      );
    } else if (detail != null) {
      final resolving = detail.busy;
      final overview = _AgentHubDetailCard(
        recipe: detail,
        busy: _busyEntryId == detail.id,
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
        onUpdate: () => _update(detail.id),
        onOpen: () => _openAgent(detail),
        onUninstall: () => _uninstall(detail),
        onVisit: () => _visit(detail),
      );
      body = AgentHubDetailTabView(
        selectedIndex: selectedIndex,
        children: [
          SingleChildScrollView(child: overview),
          if (widget.plugins != null)
            AdapterPluginPanel(
              binding: widget.plugins!,
              agentId: detail.id,
              embedded: true,
            ),
          if (widget.skills != null)
            SkillHubPanel(
              binding: widget.skills!,
              agentId: detail.id,
              embedded: true,
            ),
        ],
      );
    } else if (entries.isEmpty &&
        (projection.phase == PresentationPhase.loading || settling)) {
      body = const Center(
        key: Key('agent-hub-loading'),
        child: LicoLoadingIndicator(),
      );
    } else {
      body = CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 320),
                child: LicoSearchField(
                  query: _catalogQuery,
                  hintText: strings.isChinese ? '搜索智能体' : 'Search agents',
                  onChanged: (query) => setState(() => _catalogQuery = query),
                ),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
              child: Wrap(
                spacing: 6,
                children: [
                  for (final (filter, label) in [
                    (_AgentHubCatalogFilter.all, strings.conversationFilterAll),
                    (
                      _AgentHubCatalogFilter.installed,
                      strings.agentHubInstalled,
                    ),
                    (
                      _AgentHubCatalogFilter.missing,
                      strings.agentHubNotInstalled,
                    ),
                  ])
                    _HubFilterChip(
                      label: label,
                      selected: _catalogFilter == filter,
                      onTap: () => setState(() => _catalogFilter = filter),
                    ),
                ],
              ),
            ),
          ),
          if (projection.phase == PresentationPhase.failed)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  strings.agentHubCatalogFailed,
                  key: const Key('agent-hub-refresh-failed'),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            sliver: SliverLayoutBuilder(
              builder: (context, constraints) {
                // The design lab's `repeat(auto-fill, minmax(200px, 1fr))`:
                // as many >=200px columns as fit, then stretch to the edge.
                final columnCount = math.max(
                  1,
                  (constraints.crossAxisExtent + _hubGridGap) ~/
                      (_hubTileMinWidth + _hubGridGap),
                );
                return SliverGrid(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columnCount,
                    mainAxisExtent: _hubCardExtent,
                    mainAxisSpacing: _hubGridGap,
                    crossAxisSpacing: _hubGridGap,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final entry = catalogEntries[index];
                      final resolving = entry.busy;
                      return _HubCardEntry(
                        key: _cardEntryKey(entry.id),
                        entryId: entry.id,
                        child: _AgentHubRecipeCard(
                          recipe: entry,
                          busy: _busyEntryId == entry.id,
                          loading: resolving,
                          installLabel: strings.install,
                          updateLabel: strings.agentHubUpdate,
                          openLabel: strings.agentHubOpen,
                          retryLabel: strings.retry,
                          actions: _actionsFor(entry, resolving),
                          onOpenDetail: () => _openDetail(entry.id),
                          onInstall: () => _install(entry),
                          onUpdate: () => _update(entry.id),
                          onOpen: () => _openAgent(entry),
                          onRetryInspection: () => _retryInspection(entry.id),
                        ),
                      );
                    },
                    childCount: catalogEntries.length,
                    findChildIndexCallback: (key) {
                      // Cards settle one at a time, so the visible list grows
                      // in the middle. Matching a moved card by key keeps its
                      // entry state instead of replaying the animation.
                      return _cardEntryIndex(catalogEntries, key);
                    },
                  ),
                );
              },
            ),
          ),
        ],
      );
    }
    Widget scaffold({
      required bool refreshing,
      required VoidCallback refresh,
      required String refreshTooltip,
    }) => LayoutBuilder(
      builder: (context, constraints) {
        final available = math.max(
          0.0,
          constraints.maxWidth - LicoContentSpacing.paneTitlePadding.horizontal,
        );
        final refreshExtent = LicoIconButtonSize.medium.extent;
        const actionGaps = LicoContentSpacing.compact * 2;
        final tabsWidth = detail == null
            ? 0.0
            : math.min(
                AgentHubDetailTabs.preferredWidth(context, labels),
                math.max(0.0, available - refreshExtent - actionGaps),
              );
        final titleExtent = MediaQuery.textScalerOf(context).scale(96);
        final separateActions =
            detail != null &&
            available <
                tabsWidth + refreshExtent * 2 + actionGaps * 2 + titleExtent;
        return LicoPaneScaffold(
          key: const Key('agent-hub-panel'),
          titleBarKey: const Key('agent-hub-top-bar'),
          title: strings.agentHub,
          refreshTooltip: refreshTooltip,
          onRefresh: refreshing ? null : refresh,
          refreshing: refreshing,
          refreshButtonKey: const Key('agent-hub-refresh'),
          refreshingIconKey: const Key('agent-hub-catalog-refresh'),
          leading: detail == null
              ? null
              : LicoIconButton(
                  key: const Key('agent-hub-back'),
                  tooltip: strings.agentHubBack,
                  onPressed: () => setState(() => _detailEntryId = null),
                  icon: const Icon(Icons.arrow_back),
                ),
          trailing: detail == null
              ? null
              : SizedBox(
                  width: tabsWidth,
                  child: AgentHubDetailTabs(
                    labels: labels,
                    selectedIndex: selectedIndex,
                    onSelected: (index) =>
                        setState(() => _detailTab = destinations[index]),
                  ),
                ),
          actionsOnSeparateLine: separateActions,
          body: body,
        );
      },
    );
    final active = detail == null
        ? _AgentHubDetailDestination.overview
        : destinations[selectedIndex];
    Widget render(bool pluginsBusy, bool skillsBusy) => switch (active) {
      _AgentHubDetailDestination.plugins => scaffold(
        refreshing: pluginsBusy,
        refresh: () => widget.plugins!.intents.send(const RefreshPlugins()),
        refreshTooltip: strings.refresh,
      ),
      _AgentHubDetailDestination.skills => scaffold(
        refreshing: skillsBusy,
        refresh: () => widget.skills!.intents.send(const RefreshSkillHub()),
        refreshTooltip: strings.refreshSkills,
      ),
      _AgentHubDetailDestination.overview => scaffold(
        refreshing:
            projection.phase == PresentationPhase.loading ||
            entries.any((entry) => entry.busy),
        refresh: () => widget.binding.intents.send(const RefreshAgentHub()),
        refreshTooltip: strings.agentHubRefresh,
      ),
    };
    // Keep the same wrapper slots across selection so the embedded page state
    // survives. Only the active resource's phase participates in header updates.
    Widget observeSkills(bool pluginsBusy) {
      final binding = widget.skills;
      if (binding == null) {
        return render(pluginsBusy, false);
      }
      return ProjectionBuilder<SkillHubProjection, bool>(
        source: binding.projection,
        select: (projection) =>
            active == _AgentHubDetailDestination.skills &&
            projection.phase == PresentationPhase.loading,
        builder: (context, skillsBusy) => render(pluginsBusy, skillsBusy),
      );
    }

    final plugins = widget.plugins;
    if (plugins == null) {
      return observeSkills(false);
    }
    return ProjectionBuilder<PluginManagementProjection, bool>(
      source: plugins.projection,
      select: (projection) =>
          active == _AgentHubDetailDestination.plugins &&
          projection.phase == PresentationPhase.loading,
      builder: (context, pluginsBusy) => observeSkills(pluginsBusy),
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

_HubPrimaryKind _listPrimaryKind(AgentHubEntryProjection recipe) {
  if (recipe.present && recipe.updateAvailable) {
    return _HubPrimaryKind.update;
  }
  if (recipe.present) {
    return _HubPrimaryKind.open;
  }
  return _HubPrimaryKind.install;
}

/// The card footer: one button-height strip under the hairline. An installed
/// agent with an update splits it evenly — 更新 on the left, 对话 on the
/// right — in two distinct tones.
final class _HubCardFooter extends StatelessWidget {
  const _HubCardFooter({
    required this.recipe,
    required this.installLabel,
    required this.updateLabel,
    required this.openLabel,
    required this.actions,
    required this.onInstall,
    required this.onUpdate,
    required this.onOpen,
  });

  final AgentHubEntryProjection recipe;
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
    if (recipe.present && recipe.updateAvailable) {
      return Row(
        children: [
          Expanded(
            child: _HubFooterAction(
              actionKey: Key('agent-hub-update-${recipe.id}'),
              icon: Icons.system_update_alt_outlined,
              label: updateLabel,
              enabled: actions.updateEnabled,
              highlighted: true,
              onPressed: onUpdate,
            ),
          ),
          Container(
            width: MessagingDesktopMetrics.hairline,
            color: colors.line,
          ),
          Expanded(
            child: _HubFooterAction(
              actionKey: Key('agent-hub-open-${recipe.id}'),
              icon: Icons.chat_bubble_outline,
              label: openLabel,
              enabled: actions.openEnabled,
              onPressed: onOpen,
            ),
          ),
        ],
      );
    }
    final kind = _listPrimaryKind(recipe);
    return switch (kind) {
      _HubPrimaryKind.open => _HubFooterAction(
        actionKey: Key('agent-hub-open-${recipe.id}'),
        icon: Icons.chat_bubble_outline,
        label: openLabel,
        enabled: actions.openEnabled,
        onPressed: onOpen,
      ),
      _HubPrimaryKind.install => _HubFooterAction(
        actionKey: Key('agent-hub-install-${recipe.id}'),
        icon: Icons.download_outlined,
        label: installLabel,
        enabled: actions.installEnabled,
        onPressed: onInstall,
      ),
      _HubPrimaryKind.update => _HubFooterAction(
        actionKey: Key('agent-hub-update-${recipe.id}'),
        icon: Icons.system_update_alt_outlined,
        label: updateLabel,
        enabled: actions.updateEnabled,
        highlighted: true,
        onPressed: onUpdate,
      ),
    };
  }
}

/// One flat footer action — the full-width (or half-width) tap target the old
/// split card used: no fill of its own, icon plus label centered in the
/// 36px strip. The highlighted form marks the update half in the brand tone.
final class _HubFooterAction extends StatelessWidget {
  const _HubFooterAction({
    required this.actionKey,
    required this.icon,
    required this.label,
    required this.enabled,
    this.highlighted = false,
    required this.onPressed,
  });

  final Key actionKey;
  final IconData icon;
  final String label;
  final bool enabled;
  final bool highlighted;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final textTheme = Theme.of(context).textTheme;
    final foreground = !enabled
        ? colors.textDisabled
        : highlighted
        ? colors.primary
        : colors.textSecondary;
    final background = enabled && highlighted ? colors.brandSurface : null;
    return Material(
      color: background ?? Colors.transparent,
      child: InkWell(
        key: actionKey,
        onTap: enabled ? onPressed : null,
        child: SizedBox(
          height: _hubCardFooterExtent,
          width: double.infinity,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: _hubChipIconSize, color: foreground),
                  const SizedBox(width: LicoContentSpacing.inline),
                  Flexible(
                    child: Text(
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

TargetCandidate _brandTarget(AgentHubEntryProjection recipe) {
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

/// Fades a card in with a tiny upward settle the first time it enters the
/// grid. Cards already on screen keep their state, so a later inspection of
/// the same agent never replays the entry.
final class _HubCardEntry extends StatefulWidget {
  const _HubCardEntry({super.key, required this.entryId, required this.child});

  final String entryId;
  final Widget child;

  @override
  State<_HubCardEntry> createState() => _HubCardEntryState();
}

final class _HubCardEntryState extends State<_HubCardEntry>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: LicoMotion.medium,
  );
  late final CurvedAnimation _entrance = CurvedAnimation(
    parent: _controller,
    curve: LicoMotion.decelerate,
  );
  late final Animation<Offset> _settle = Tween<Offset>(
    begin: const Offset(0, 0.04),
    end: Offset.zero,
  ).animate(_entrance);
  bool _entering = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final duration = context.motion(LicoMotion.medium);
    _controller.duration = duration;
    if (duration == Duration.zero) {
      // Reduced motion: the card is simply there, fully settled.
      _controller.value = 1;
    } else if (!_entering) {
      _controller.forward();
    }
    _entering = true;
  }

  @override
  void dispose() {
    _entrance.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      key: Key('agent-hub-card-fade-${widget.entryId}'),
      opacity: _entrance,
      child: SlideTransition(
        key: Key('agent-hub-card-settle-${widget.entryId}'),
        position: _settle,
        child: widget.child,
      ),
    );
  }
}

/// The failed-card footer. It replaces the primary action so a card whose
/// inspection failed offers its own re-inspection instead of dead text.
final class _HubRetryButton extends StatelessWidget {
  const _HubRetryButton({
    required this.recipeId,
    required this.label,
    required this.enabled,
    required this.onRetry,
  });

  final String recipeId;
  final String label;
  final bool enabled;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final textTheme = Theme.of(context).textTheme;
    final foreground = enabled ? colors.error : colors.textDisabled;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: Key('agent-hub-retry-$recipeId'),
        onTap: enabled ? onRetry : null,
        child: SizedBox(
          height: _hubCardFooterExtent,
          width: double.infinity,
          child: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.refresh, size: _hubChipIconSize, color: foreground),
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

final class _AgentHubRecipeCard extends StatelessWidget {
  const _AgentHubRecipeCard({
    required this.recipe,
    required this.busy,
    required this.loading,
    required this.installLabel,
    required this.updateLabel,
    required this.openLabel,
    required this.retryLabel,
    required this.actions,
    required this.onOpenDetail,
    required this.onInstall,
    required this.onUpdate,
    required this.onOpen,
    required this.onRetryInspection,
  });

  final AgentHubEntryProjection recipe;
  final bool busy;
  final bool loading;
  final String installLabel;
  final String updateLabel;
  final String openLabel;
  final String retryLabel;
  final _HubCardActions actions;
  final VoidCallback onOpenDetail;
  final VoidCallback onInstall;
  final VoidCallback onUpdate;
  final VoidCallback onOpen;
  final VoidCallback onRetryInspection;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final textTheme = Theme.of(context).textTheme;
    final strings = LicoStrings.of(context);
    final statusLabel = recipe.present
        ? recipe.versionLabel.isEmpty
              ? strings.agentHubInstalled
              : '${strings.agentHubInstalled} ${recipe.versionLabel}'
        : strings.agentHubNotInstalled;
    return _HubTileSurface(
      key: Key('agent-hub-card-${recipe.id}'),
      child: LicoShimmerMask(
        key: loading ? Key('agent-hub-card-loading-${recipe.id}') : null,
        enabled: loading,
        child: Material(
          color: Colors.transparent,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Stack(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        _hubTilePadding,
                        _hubTilePadding,
                        _hubTilePadding,
                        0,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          AgentBrandIcon(
                            key: Key('agent-hub-header-${recipe.id}'),
                            target: _brandTarget(recipe),
                            size: _hubTileAvatarSize,
                            iconSize: _hubTileAvatarGlyphSize,
                          ),
                          const SizedBox(height: _hubTileAvatarToNameGap),
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  recipe.displayName,
                                  key: Key('agent-hub-name-${recipe.id}'),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: textTheme.titleSmall?.copyWith(
                                    color: colors.text,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              for (final badge in _tileBadges(recipe)) ...[
                                const SizedBox(width: 4),
                                badge,
                              ],
                            ],
                          ),
                          const SizedBox(height: _hubTileNameToDescGap),
                          // The summary gives way first: it is clipped to
                          // whatever room remains while the status row keeps
                          // its seat at the bottom of the upper region.
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: ClipRect(
                                    child: Text(
                                      recipe.summary,
                                      key: Key(
                                        'agent-hub-summary-${recipe.id}',
                                      ),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: textTheme.bodySmall?.copyWith(
                                        color: colors.textMuted,
                                        fontSize: 12,
                                        height: 1.4,
                                      ),
                                    ),
                                  ),
                                ),
                                Row(
                                  children: [
                                    Container(
                                      width: _hubStatusDotSize,
                                      height: _hubStatusDotSize,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: recipe.present
                                            ? colors.success
                                            : colors.textDisabled,
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: Text(
                                        statusLabel,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: textTheme.bodySmall?.copyWith(
                                          fontSize: 12,
                                          color: recipe.present
                                              ? colors.textSecondary
                                              : colors.textMuted,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(
                                  height: _hubTileStatusToActionGap,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    // The detail affordance is a corner chevron, not the
                    // whole tile: tapping a card performs no navigation.
                    Positioned(
                      top: 8,
                      right: 8,
                      child: LicoIconButton(
                        key: Key('agent-hub-intro-${recipe.id}'),
                        tooltip: strings.isChinese ? '详情' : 'Details',
                        onPressed: onOpenDetail,
                        size: LicoIconButtonSize.small,
                        shape: LicoIconButtonShape.circle,
                        icon: const Icon(Icons.chevron_right_rounded, size: 16),
                      ),
                    ),
                  ],
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
              recipe.resolutionFailed
                  ? _HubRetryButton(
                      recipeId: recipe.id,
                      label: retryLabel,
                      enabled: !recipe.busy,
                      onRetry: onRetryInspection,
                    )
                  : _HubCardFooter(
                      recipe: recipe,
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
      ),
    );
  }
}

/// The design lab's `.agent-tile`: `--bg-subtle` fill, 16px radius, hairline
/// border, and a 2px hover lift with the card shadow. Kept local to the tile
/// so the detail card can keep the shared [AgentHubSurface] elevation.
final class _HubTileSurface extends StatefulWidget {
  const _HubTileSurface({super.key, required this.child});

  final Widget child;

  @override
  State<_HubTileSurface> createState() => _HubTileSurfaceState();
}

final class _HubTileSurfaceState extends State<_HubTileSurface> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    const borderRadius = BorderRadius.all(Radius.circular(16));
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: context.motion(LicoMotion.micro),
        curve: LicoMotion.standard,
        transform: Matrix4.translationValues(0, _hovered ? -2 : 0, 0),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: colors.isDark
              ? LicoPaneGlass.contentInnerCardFill
              : (colors.isDark
                    ? LicoPaneGlass.contentInnerCardFill
                    : colors.surfaceLow),
          borderRadius: borderRadius,
          boxShadow: _hovered ? LicoElevation.raised.shadows(colors) : const [],
        ),
        foregroundDecoration: continuousHairlineDecoration(
          color: Colors.transparent,
          borderRadius: borderRadius,
          stroke: colors.line,
          strokeWidth: MessagingDesktopMetrics.hairline,
        ),
        child: Material(type: MaterialType.transparency, child: widget.child),
      ),
    );
  }
}

/// Badges after the agent name: one per install form actually detected on
/// this host — Desktop, CLI, IDE or Plugin. An undetected entry shows none.
List<Widget> _tileBadges(AgentHubEntryProjection recipe) {
  return [
    for (final kind in recipe.installKinds)
      if (_installKindBadgeLabel(kind) != null)
        _HubTileBadge(label: _installKindBadgeLabel(kind)!),
  ];
}

String? _installKindBadgeLabel(String kind) {
  return switch (kind.trim().toLowerCase()) {
    'desktop' => 'Desktop',
    'cli' => 'CLI',
    'ide' => 'IDE',
    'plugin' => 'Plugin',
    _ => null,
  };
}

/// The install-form tag after the agent name — Desktop / CLI / IDE / Plugin
/// as reported by the target scan.
final class _HubTileBadge extends StatelessWidget {
  const _HubTileBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: continuousHairlineDecoration(
        color: colors.brandSurface,
        borderRadius: BorderRadius.circular(5),
        stroke: colors.brandBorder,
        strokeWidth: 0.5,
      ),
      child: Text(
        label,
        style: TextStyle(
          color: colors.accent,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          height: 1.3,
        ),
      ),
    );
  }
}

/// The view-filter chips above the catalog grid (全部 / 已安装 / 未安装).
final class _HubFilterChip extends StatelessWidget {
  const _HubFilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final foreground = selected ? colors.selectionInk : colors.textSecondary;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: const BorderRadius.all(Radius.circular(999)),
        child: Ink(
          decoration: continuousHairlineDecoration(
            color: selected
                ? colors.brandSurface
                : (colors.isDark
                      ? LicoPaneGlass.contentInnerCardFill
                      : colors.surfaceLow),
            borderRadius: const BorderRadius.all(Radius.circular(999)),
            stroke: selected ? colors.brandBorder : colors.line,
            strokeWidth: MessagingDesktopMetrics.hairline,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
            child: Text(
              label,
              style: TextStyle(
                color: foreground,
                fontSize: 12,
                fontWeight: FontWeight.w600,
                height: 1.4,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final class _AgentHubDetailCard extends StatelessWidget {
  const _AgentHubDetailCard({
    required this.recipe,
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

  final AgentHubEntryProjection recipe;
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
    final strings = LicoStrings.of(context);
    final installedLabel = recipe.present
        ? recipe.versionLabel.isEmpty
              ? strings.agentHubInstalled
              : '${strings.agentHubInstalled} ${recipe.versionLabel}'
        : strings.agentHubNotInstalled;
    final meta = [
      if (recipe.channelLabel.isNotEmpty) recipe.channelLabel,
      installedLabel,
    ].join(' · ');
    final statusText = recipe.actionStateLabel.isNotEmpty
        ? recipe.actionStateLabel
        : installedLabel;
    final isChinese = strings.isChinese;
    final facts = <(String, String)>[
      (
        isChinese ? '版本' : 'Version',
        recipe.versionLabel.isEmpty ? '—' : recipe.versionLabel,
      ),
      (
        isChinese ? '渠道' : 'Channel',
        recipe.channelLabel.isEmpty ? '—' : recipe.channelLabel,
      ),
      (
        isChinese ? '适配' : 'Adaptation',
        switch (recipe.adaptation) {
          AgentHubAdaptationProjection.deep => isChinese ? '深度适配' : 'Deep',
          AgentHubAdaptationProjection.partial =>
            isChinese ? '部分适配' : 'Partial',
          AgentHubAdaptationProjection.pending => isChinese ? '检测中' : 'Pending',
        },
      ),
      (
        isChinese ? '归属' : 'Owner',
        recipe.owned ? 'LicoUp' : (isChinese ? '第三方' : 'External'),
      ),
    ];
    // The design lab's `.profile-card`: a 320px glass pop — gradient cover,
    // ringed avatar overlapping it, name + badge, meta line, status pill,
    // description, a two-column fact grid, capability chips and a full-width
    // action row.
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: 1),
          duration: context.motion(LicoMotion.short),
          curve: const Cubic(0.34, 1.56, 0.64, 1),
          builder: (context, t, child) => Transform.scale(
            scale: 0.96 + 0.04 * t,
            child: Opacity(opacity: t.clamp(0.0, 1.0), child: child),
          ),
          child: Container(
            key: Key('agent-hub-detail-${recipe.id}'),
            margin: const EdgeInsets.only(top: 12, bottom: 24),
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color:
                  (colors.isDark
                          ? LicoPaneGlass.contentInnerCardFill
                          : colors.surfaceRaised)
                      .withValues(
                        alpha: context.appearanceVisuals.surfaceOpacity,
                      ),
              borderRadius: BorderRadius.circular(20),
              boxShadow: LicoElevation.raised.shadows(colors),
            ),
            foregroundDecoration: continuousHairlineDecoration(
              borderRadius: BorderRadius.circular(20),
              color: Colors.transparent,
              stroke: colors.isDark
                  ? Colors.white.withValues(alpha: 0.08)
                  : colors.line,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  height: 112,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      const Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        height: 76,
                        child: LicoProfileCover(),
                      ),
                      Positioned(
                        top: 40,
                        left: 18,
                        child: LicoProfileAvatarRing(
                          child: AgentBrandIcon(
                            target: _brandTarget(recipe),
                            size: 72,
                            iconSize: 44,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 12, 18, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              recipe.displayName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: textTheme.titleLarge?.copyWith(
                                fontSize: 20,
                                fontWeight: FontWeight.w600,
                                color: colors.text,
                              ),
                            ),
                          ),
                          for (final badge in _tileBadges(recipe)) ...[
                            const SizedBox(width: 6),
                            badge,
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        meta,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodySmall?.copyWith(
                          fontSize: 12,
                          color: colors.textMuted,
                        ),
                      ),
                      const SizedBox(height: 9),
                      LicoProfileStatusPill(
                        label: statusText,
                        dotColor: busy || loading
                            ? colors.primary
                            : recipe.present
                            ? colors.success
                            : colors.warning,
                      ),
                      const SizedBox(height: 10),
                      Text(
                        recipe.summary,
                        key: Key('agent-hub-summary-${recipe.id}'),
                        style: textTheme.bodySmall?.copyWith(
                          fontSize: 13,
                          color: colors.textSecondary,
                          height: 1.5,
                        ),
                      ),
                      const SizedBox(height: 12),
                      LicoProfileFactGrid(
                        facts: facts,
                        firstValueKey: Key('agent-hub-version-${recipe.id}'),
                      ),
                      if (recipe.channels.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            for (final channel in recipe.channels.take(8))
                              LicoProfileCapChip(label: channel.chipLabel),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          if (!recipe.present && recipe.installable)
                            Expanded(
                              child: LicoProfileAction(
                                actionKey: Key(
                                  'agent-hub-install-${recipe.id}',
                                ),
                                icon: Icons.download_outlined,
                                label: installLabel,
                                enabled: actions.installEnabled,
                                kind: LicoProfileActionKind.filled,
                                onPressed: onInstall,
                              ),
                            ),
                          if (recipe.present)
                            Expanded(
                              child: LicoProfileAction(
                                actionKey: Key('agent-hub-open-${recipe.id}'),
                                icon: Icons.chat_bubble_outline,
                                label: openLabel,
                                enabled: actions.openEnabled,
                                kind: LicoProfileActionKind.filled,
                                onPressed: onOpen,
                              ),
                            ),
                          if (recipe.present && recipe.updateAvailable) ...[
                            const SizedBox(width: 8),
                            Expanded(
                              child: LicoProfileAction(
                                actionKey: Key('agent-hub-update-${recipe.id}'),
                                icon: Icons.system_update_alt_outlined,
                                label: updateLabel,
                                enabled: actions.updateEnabled,
                                kind: LicoProfileActionKind.filled,
                                onPressed: onUpdate,
                              ),
                            ),
                          ],
                          if (recipe.officialHomepage != null) ...[
                            const SizedBox(width: 8),
                            Expanded(
                              child: LicoProfileAction(
                                actionKey: Key('agent-hub-visit-${recipe.id}'),
                                label: visitFailed
                                    ? visitFailedLabel
                                    : visitLabel,
                                trailingIcon: Icons.arrow_forward_rounded,
                                onPressed: onVisit,
                              ),
                            ),
                          ],
                        ],
                      ),
                      if (recipe.showsManageActions) ...[
                        const SizedBox(height: 8),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: LicoProfileAction(
                            actionKey: Key('agent-hub-uninstall-${recipe.id}'),
                            icon: Icons.delete_outline,
                            label: uninstallLabel,
                            enabled: actions.uninstallEnabled,
                            kind: LicoProfileActionKind.danger,
                            onPressed: onUninstall,
                          ),
                        ),
                      ],
                      if (loading || busy) ...[
                        const SizedBox(height: 12),
                        LinearProgressIndicator(
                          key: Key(
                            loading
                                ? 'agent-hub-card-loading-${recipe.id}'
                                : 'agent-hub-card-busy',
                          ),
                          minHeight: 2,
                        ),
                      ],
                      if (recipe.resolutionFailed) ...[
                        const SizedBox(height: 12),
                        Text(
                          isChinese
                              ? '状态加载失败，请刷新重试。'
                              : 'Status unavailable. Refresh to try again.',
                          style: textTheme.bodySmall?.copyWith(
                            color: colors.error,
                          ),
                        ),
                      ],
                      if (events.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        Text(
                          events.join(' · '),
                          key: Key('agent-hub-events-${recipe.id}'),
                          style: textTheme.bodySmall?.copyWith(
                            color: colors.textMuted,
                          ),
                        ),
                      ],
                    ],
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
