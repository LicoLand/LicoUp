import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/binding/effect_listener.dart';
import 'package:licoup/src/frontend/binding/projection_builder.dart';
import 'package:licoup/src/frontend/features/agent_hub/ui/agent_hub_install_dialog.dart';
import 'package:licoup/src/frontend/features/agent_hub/ui/agent_hub_summary_visit.dart';
import 'package:licoup/src/frontend/features/agent_hub/ui/agent_hub_uninstall_dialog.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/agent_brand_icon.dart';
import 'package:licoup/src/frontend/shared/ui/lico_activity_animations.dart';
import 'package:licoup/src/frontend/shared/ui/lico_content_spacing.dart';
import 'package:licoup/src/frontend/shared/ui/lico_icon_button.dart';
import 'package:licoup/src/frontend/shared/ui/lico_pane_scaffold.dart';
import 'package:licoup/src/frontend/shared/ui/lico_radius.dart';
import 'package:licoup/src/frontend/shared/ui/messaging_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/agent_hub/agent_hub_binding.dart';
import 'package:licoup/src/presentation/agent_hub/agent_hub_effect.dart';
import 'package:licoup/src/presentation/agent_hub/agent_hub_intent.dart';
import 'package:licoup/src/presentation/agent_hub/agent_hub_projection.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';

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
    List<AgentHubEntryProjection> Function(
      List<AgentHubEntryProjection> recipes,
    );

List<AgentHubEntryProjection> shuffleAgentHubRecipes(
  List<AgentHubEntryProjection> recipes,
) {
  final next = List<AgentHubEntryProjection>.from(recipes);
  next.shuffle(math.Random());
  return next;
}

typedef AgentHubExternalOpener = Future<void> Function(Uri uri);
typedef AgentHubOpenAgent = ValueChanged<String>;

/// Pure semantic Agent Hub renderer. All catalog state and lifecycle work enter
/// through [AgentHubBinding]; this widget owns only transient presentation state.
final class AgentHubPanel extends StatefulWidget {
  const AgentHubPanel({
    super.key,
    required this.binding,
    this.openHomepage,
    this.onOpenAgent,
    this.orderEntries = shuffleAgentHubRecipes,
  });

  final AgentHubBinding binding;
  final AgentHubExternalOpener? openHomepage;
  final AgentHubOpenAgent? onOpenAgent;
  final AgentHubCatalogOrder orderEntries;

  @override
  State<AgentHubPanel> createState() => _AgentHubPanelState();
}

final class _AgentHubPanelState extends State<AgentHubPanel> {
  List<AgentHubEntryProjection> _entries = const [];
  final Set<String> _orderedIds = {};
  String _busyEntryId = '';
  String? _detailEntryId;
  final Map<String, List<String>> _events = {};
  final Set<String> _visitFailed = {};
  int _refreshRevision = -1;

  AgentHubEntryProjection? get _detailEntry {
    final id = _detailEntryId;
    if (id == null) return null;
    return _entries.where((entry) => entry.id == id).firstOrNull;
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
        widget.orderEntries(incoming),
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
    return _entries;
  }

  Future<void> _install(AgentHubEntryProjection entry) async {
    if (entry.busy || !entry.installable || entry.installed) return;
    final selection = await showAgentHubInstallFlow(context, recipe: entry);
    if (selection == null || !mounted) return;
    setState(() => _busyEntryId = entry.id);
    widget.binding.intents.send(
      InstallAgentHubEntry(
        entry.id,
        channelId: selection.channelId,
        version: selection.version,
      ),
    );
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

  void _visit(AgentHubEntryProjection entry) {
    if (entry.busy || entry.officialHomepage == null) {
      setState(() => _visitFailed.add(entry.id));
      return;
    }
    widget.binding.intents.send(OpenAgentHubHomepage(entry.id));
  }

  _HubCardActions _actionsFor(AgentHubEntryProjection entry, bool resolving) {
    final locked = resolving || _busyEntryId == entry.id;
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
    Widget body;
    if (projection.phase == PresentationPhase.loading && entries.isEmpty) {
      body = const Center(
        key: Key('agent-hub-loading'),
        child: CircularProgressIndicator(),
      );
    } else if (projection.phase == PresentationPhase.failed &&
        entries.isEmpty) {
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
      body = _AgentHubDetailCard(
        recipe: detail,
        adaptationLabel: switch (detail.adaptation) {
          AgentHubAdaptationProjection.deep => strings.adaptationDeep,
          AgentHubAdaptationProjection.partial => strings.adaptationPartial,
          AgentHubAdaptationProjection.pending => strings.adaptationPending,
        },
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
              final entry = entries[index];
              final resolving = entry.busy;
              return _AgentHubRecipeCard(
                recipe: entry,
                busy: _busyEntryId == entry.id,
                loading: resolving,
                installLabel: strings.install,
                updateLabel: strings.agentHubUpdate,
                openLabel: strings.agentHubOpen,
                actions: _actionsFor(entry, resolving),
                onOpenDetail: () => setState(() => _detailEntryId = entry.id),
                onInstall: () => _install(entry),
                onUpdate: () => _update(entry.id),
                onOpen: () => _openAgent(entry),
              );
            }, childCount: entries.length),
          ),
        ],
      );
    }
    return LicoPaneScaffold(
      key: const Key('agent-hub-panel'),
      titleBarKey: const Key('agent-hub-top-bar'),
      title: detail?.displayName ?? strings.agentHub,
      refreshTooltip: strings.agentHubRefresh,
      onRefresh: () => widget.binding.intents.send(const RefreshAgentHub()),
      refreshing:
          projection.phase == PresentationPhase.loading ||
          entries.any((entry) => entry.busy),
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

_HubPrimaryKind _listPrimaryKind(AgentHubEntryProjection recipe) {
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

  final AgentHubEntryProjection recipe;
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

  final AgentHubEntryProjection recipe;
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
      AgentHubAdaptationProjection.deep => colors.success,
      AgentHubAdaptationProjection.partial => colors.warning,
      AgentHubAdaptationProjection.pending => colors.textMuted,
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
                      if (recipe.channelLabel.isNotEmpty)
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
                            recipe.channelLabel,
                            style: textTheme.labelSmall?.copyWith(
                              color: colors.textSecondary,
                              height: 1,
                            ),
                          ),
                        ),
                      if (recipe.versionLabel.isNotEmpty) ...[
                        if (recipe.channelLabel.isNotEmpty)
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
