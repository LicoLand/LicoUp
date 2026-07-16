import 'dart:async';

import 'package:flutter/material.dart';

import 'package:flutter_client/src/application/controller/client_controller.dart';
import 'package:flutter_client/src/application/features/layout/layout_state_store.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_client/src/contracts/presentation/layout_state_namespace.dart';
import 'package:flutter_client/src/contracts/target_candidate.dart';
import 'package:flutter_client/src/frontend/layout/layout_destination_presentation.dart';
import 'package:flutter_client/src/frontend/layout/layout_palette.dart';
import 'package:flutter_client/src/frontend/layout/layout_scope.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/agent_conversation_pane.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/conversation_archive_dialog.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/agent_conversation_composer.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/agent_conversation_layout_metrics.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/agent_conversation_message_display.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/agent_conversation_session_presentation.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/agent_usage_panel.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/agent_workspace_sidebar.dart';
import 'package:flutter_client/src/frontend/features/skill_hub/ui/skill_hub_panel.dart';
import 'package:flutter_client/src/frontend/shared/platform/client_platform.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/history_session_panel.dart';
import 'package:flutter_client/src/frontend/shared/ui/panel_frame.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';

class AgentConversationWorkspace extends StatefulWidget {
  const AgentConversationWorkspace({
    super.key,
    required this.controller,
    required this.targets,
    required this.scanning,
    required this.adding,
    required this.onAddTarget,
    this.allowManualTargetActions = true,
  });

  final ClientController controller;
  final List<TargetCandidate> targets;
  final bool scanning;
  final bool adding;
  final VoidCallback onAddTarget;
  final bool allowManualTargetActions;

  @override
  State<AgentConversationWorkspace> createState() =>
      _AgentConversationWorkspaceState();
}

class _AgentConversationWorkspaceState
    extends State<AgentConversationWorkspace> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_handleControllerChanged);
    widget.controller.conversationStructureListenable.addListener(
      _handleControllerChanged,
    );
  }

  @override
  void didUpdateWidget(covariant AgentConversationWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) {
      return;
    }
    oldWidget.controller.removeListener(_handleControllerChanged);
    oldWidget.controller.conversationStructureListenable.removeListener(
      _handleControllerChanged,
    );
    widget.controller.addListener(_handleControllerChanged);
    widget.controller.conversationStructureListenable.addListener(
      _handleControllerChanged,
    );
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleControllerChanged);
    widget.controller.conversationStructureListenable.removeListener(
      _handleControllerChanged,
    );
    super.dispose();
  }

  void _handleControllerChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final mobileClient =
        widget.controller.mobileClientRuntimePlatform ||
        isMobileClientPlatform(context);
    final targets = widget.controller.orderedConversationTargets(
      widget.targets,
    );
    // Desktop owns agent navigation in the sidebar tree; mobile owns it in the
    // phone shell. The workspace itself stays independent of layout profiles.
    return _ConversationWorkspaceBody(
      controller: widget.controller,
      targets: targets,
      scanning: widget.scanning,
      adding: widget.adding,
      onAddTarget: widget.onAddTarget,
      allowManualTargetActions: widget.allowManualTargetActions,
      useFloatingShell: !mobileClient,
    );
  }
}

class _ConversationWorkspaceBody extends StatefulWidget {
  const _ConversationWorkspaceBody({
    required this.controller,
    required this.targets,
    required this.scanning,
    required this.adding,
    required this.onAddTarget,
    required this.allowManualTargetActions,
    this.useFloatingShell = false,
  });

  final ClientController controller;
  final List<TargetCandidate> targets;
  final bool scanning;
  final bool adding;
  final VoidCallback onAddTarget;
  final bool allowManualTargetActions;
  final bool useFloatingShell;

  @override
  State<_ConversationWorkspaceBody> createState() =>
      _ConversationWorkspaceBodyState();
}

class _ConversationWorkspaceBodyState
    extends State<_ConversationWorkspaceBody> {
  bool _historyCollapsed = false;
  // Default to the narrowest usable rail; users can drag wider.
  double _sidebarWidth = agentsSidebarMinWidth;
  AgentsWorkspaceDestination _destination =
      AgentsWorkspaceDestination.conversations;
  LayoutScopedState? _layoutState;
  String? _layoutStateIdentity;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scope = LayoutScope.maybeOf(context);
    if (scope == null) {
      _layoutState = null;
      _layoutStateIdentity = null;
      return;
    }
    final identity =
        '${scope.profileId.value}/${scope.environment.surface.name}';
    if (_layoutStateIdentity == identity) {
      return;
    }
    _layoutStateIdentity = identity;
    _layoutState = scope.state;

    final history = scope.state.readIfDeclared(
      LayoutStateChannels.agentsHistory,
    );
    final sidebar = scope.state.readIfDeclared(
      LayoutStateChannels.agentsSidebar,
    );
    final destination = scope.state.readIfDeclared(
      LayoutStateChannels.agentsDestination,
    );
    _historyCollapsed = history is LayoutExpansionState
        ? !history.expanded
        : false;
    _sidebarWidth = sidebar is LayoutPaneExtentState
        ? sidebar.extent.clamp(agentsSidebarMinWidth, agentsSidebarMaxWidth)
        : agentsSidebarMinWidth;
    _destination =
        destination is LayoutTabState &&
            destination.index < AgentsWorkspaceDestination.values.length
        ? AgentsWorkspaceDestination.values[destination.index]
        : AgentsWorkspaceDestination.conversations;
  }

  void _writeLayoutState(
    LayoutStateChannel channel,
    LayoutPresentationStateValue value,
  ) {
    _layoutState?.writeIfDeclared(channel, value);
  }

  void _toggleHistoryCollapsed() {
    setState(() => _historyCollapsed = !_historyCollapsed);
    _writeLayoutState(
      LayoutStateChannels.agentsHistory,
      LayoutExpansionState(!_historyCollapsed),
    );
  }

  void _selectDestination(AgentsWorkspaceDestination destination) {
    if (_destination == destination) {
      return;
    }
    setState(() => _destination = destination);
    _writeLayoutState(
      LayoutStateChannels.agentsDestination,
      LayoutTabState(destination.index),
    );
  }

  Widget _detailForDestination({
    required TargetCandidate? target,
    required Widget conversationPane,
  }) {
    return switch (_destination) {
      AgentsWorkspaceDestination.skills => SkillHubPanel(
        controller: widget.controller,
      ),
      AgentsWorkspaceDestination.stats => AgentUsagePanel(
        controller: widget.controller,
      ),
      AgentsWorkspaceDestination.conversations =>
        target == null
            ? AgentConversationEmptySelection(
                allowManualTargetActions: widget.allowManualTargetActions,
                onAddTarget: widget.onAddTarget,
              )
            : conversationPane,
    };
  }

  Widget _buildFloatingShell({
    required ClientController controller,
    required TargetCandidate? target,
    required Widget conversationPane,
    required VoidCallback onAddTarget,
    required bool allowManualTargetActions,
    required LicoStrings strings,
    required LayoutAgentsPresentation presentation,
  }) {
    return ColoredBox(
      key: const Key('agents-workspace-shell'),
      color: presentation.canvasColor(context.layoutPalette),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final maxSidebarWidth =
              (constraints.maxWidth -
                      agentsSidebarDividerWidth -
                      agentsFloatingMinChatWidth -
                      presentation.sidebarOuterHorizontalExtent -
                      presentation.detailOuterHorizontalExtent)
                  .clamp(agentsSidebarMinWidth, agentsSidebarMaxWidth)
                  .toDouble();
          final sidebarWidth = _sidebarWidth
              .clamp(agentsSidebarMinWidth, maxSidebarWidth)
              .toDouble();
          final sidebar = AgentsWorkspaceSidebar(
            destination: _destination,
            onSelectDestination: _selectDestination,
            targets: widget.targets,
            sessionsByAgent: controller.conversationSessionsByAgent,
            selectedAgentId: controller.selectedConversationAgentId,
            selectedSessionId: controller.selectedConversationSession?.id ?? '',
            activityFor: controller.conversationTabActivityFor,
            onSelectAgent: (agentId) =>
                unawaited(controller.selectConversationAgent(agentId)),
            onSelectSession: (agentId, sessionId) async {
              await controller.selectConversationAgent(agentId);
              controller.selectConversationSession(sessionId);
            },
            onNewConversation: controller.startNewConversationSession,
            onArchive: () => unawaited(
              showConversationArchiveDialog(
                context,
                controller,
                sourceAgentId: '',
              ),
            ),
            onAddTarget: onAddTarget,
            allowManualTargetActions: allowManualTargetActions,
            scanning: widget.scanning,
            adding: widget.adding,
          );
          final detail = _detailForDestination(
            target: target,
            conversationPane: conversationPane,
          );
          final sidebarPane = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (presentation.showExpandedSidebarControl)
                Padding(
                  padding: presentation.expandedSidebarControlPadding,
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: AgentsSidebarCollapseControl(
                      key: const Key('agents-workspace-sidebar-collapse'),
                      expanded: true,
                      tooltip: strings.collapseAgentsSidebar,
                      onPressed: _toggleHistoryCollapsed,
                    ),
                  ),
                ),
              Expanded(child: sidebar),
            ],
          );
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_historyCollapsed && presentation.showCollapsedSidebarControl)
                Padding(
                  padding: presentation.collapsedSidebarControlPadding,
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: AgentsSidebarCollapseControl(
                      key: const Key('agents-workspace-sidebar-expand'),
                      expanded: false,
                      tooltip: strings.expandAgentsSidebar,
                      onPressed: _toggleHistoryCollapsed,
                    ),
                  ),
                )
              else if (!_historyCollapsed)
                presentation.frameSidebar(
                  context,
                  key: const Key('agents-workspace-sidebar-card'),
                  child: SizedBox(width: sidebarWidth, child: sidebarPane),
                ),
              Expanded(
                child: PaneEdgeDragHandle(
                  dragHandleKey: const Key('agents-workspace-split-divider'),
                  width: agentsSidebarDividerWidth,
                  enabled: !_historyCollapsed,
                  onDragDelta: (delta) {
                    setState(() {
                      _sidebarWidth = (sidebarWidth + delta)
                          .clamp(agentsSidebarMinWidth, maxSidebarWidth)
                          .toDouble();
                    });
                    _writeLayoutState(
                      LayoutStateChannels.agentsSidebar,
                      LayoutPaneExtentState(_sidebarWidth),
                    );
                  },
                  child: presentation.frameDetail(
                    context,
                    key: const Key('agents-workspace-floating-card'),
                    sidebarCollapsed: _historyCollapsed,
                    child: detail,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final onAddTarget = widget.onAddTarget;
    final allowManualTargetActions = widget.allowManualTargetActions;
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final target = controller.selectedConversationAgent;
    final mobileClient = isMobileClientPlatform(context);

    if (widget.useFloatingShell && !mobileClient) {
      final presentation = LayoutDestinationPresentationScope.agentsOf(context);
      final conversationPane = target == null
          ? const SizedBox.shrink()
          : AgentConversationActivePane(
              controller: controller,
              target: target,
              historyCollapsed: _historyCollapsed,
              onToggleHistory: _toggleHistoryCollapsed,
              collapseHistoryTooltip: strings.collapseHistoryConversations,
              expandHistoryTooltip: strings.expandHistoryConversations,
              framed: false,
              showSidebarToggle: presentation.showConversationSidebarControl,
            );
      return _buildFloatingShell(
        controller: controller,
        target: target,
        conversationPane: conversationPane,
        onAddTarget: onAddTarget,
        allowManualTargetActions: allowManualTargetActions,
        strings: strings,
        presentation: presentation,
      );
    }

    if (target == null) {
      if (mobileClient) {
        return Column(
          children: [
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.psychology_outlined,
                        color: colors.textMuted,
                        size: 26,
                      ),
                      const SizedBox(height: 10),
                      Text(
                        strings.selectAgentToView,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: colors.textMuted),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            MobileComposerSurface(
              child: InactiveRuntimeMessageComposer(targetLabel: strings.agent),
            ),
          ],
        );
      }
      return PanelFrame(
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.psychology_outlined,
                        color: colors.textMuted,
                        size: 28,
                      ),
                      const SizedBox(height: 10),
                      Text(
                        strings.selectAgentToView,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: colors.textMuted),
                      ),
                      if (allowManualTargetActions) ...[
                        const SizedBox(height: 14),
                        OutlinedButton.icon(
                          onPressed: onAddTarget,
                          icon: const Icon(Icons.add, size: 18),
                          label: Text(strings.addTarget),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            if (mobileClient) ...[
              const Divider(height: 1),
              InactiveRuntimeMessageComposer(targetLabel: strings.agent),
            ],
          ],
        ),
      );
    }

    final sessions = controller.selectedConversationSessions;
    final selectedSession = controller.selectedConversationSession;
    final selectedSessionId = selectedSession?.id ?? '';
    final historyItems = sessions
        .map((session) {
          final workingDirectory = session.workingDirectory.trim();
          final nativeId = session.nativeSessionId.trim();
          final running =
              controller.isSendingConversationMessage &&
              ((controller.sendingConversationSessionId.isNotEmpty &&
                      session.id == controller.sendingConversationSessionId) ||
                  (controller.sendingConversationNativeSessionId.isNotEmpty &&
                      nativeId ==
                          controller.sendingConversationNativeSessionId) ||
                  (controller.sendingConversationSessionId.isEmpty &&
                      controller.sendingConversationNativeSessionId.isEmpty &&
                      session.id == selectedSessionId));
          return HistorySessionPanelItem(
            id: session.id,
            title: session.title,
            meta: conversationSessionRelativeUpdatedAtLabel(session),
            preview: conversationMessagePreviewText(session.preview),
            groupKey: workingDirectory,
            groupLabel: historySessionProjectLabel(
              workingDirectory,
              fallback: strings.ungroupedConversationProject,
            ),
            active: session.id == selectedSessionId,
            running: running,
            canDelete: false,
            deleteLabel: strings.deleteNativeHistory,
          );
        })
        .toList(growable: false);
    if (mobileClient) {
      return AgentConversationActivePane(
        controller: controller,
        target: target,
        historyCollapsed: _historyCollapsed,
        onToggleHistory: _toggleHistoryCollapsed,
        collapseHistoryTooltip: strings.collapseHistoryConversations,
        expandHistoryTooltip: strings.expandHistoryConversations,
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 760;
        final chatPane = AgentConversationActivePane(
          controller: controller,
          target: target,
          historyCollapsed: _historyCollapsed,
          onToggleHistory: _toggleHistoryCollapsed,
          collapseHistoryTooltip: strings.collapseHistoryConversations,
          expandHistoryTooltip: strings.expandHistoryConversations,
        );
        HistorySessionPanel historyPaneFor(
          double maxListHeight, {
          bool framed = true,
          double? headerHeight,
        }) {
          return HistorySessionPanel(
            title: strings.historyConversations,
            subtitle: '',
            loading: controller.isLoadingConversations,
            items: historyItems,
            onSelect: controller.selectConversationSession,
            emptyLabel: strings.noNativeHistories,
            loadingLabel: strings.loadingNativeHistories,
            maxListHeight: maxListHeight,
            framed: framed,
            showHeaderText: false,
            collapsible: false,
            collapsed: _historyCollapsed,
            collapseTooltip: strings.collapseHistoryConversations,
            expandTooltip: strings.expandHistoryConversations,
            headerHeight: headerHeight,
            hasMore: controller.selectedConversationSessionsHasMore,
            loadingMore: controller.isLoadingMoreSelectedConversationSessions,
            groupByProject: true,
            onLoadMore: () => unawaited(
              controller.loadMoreConversationSessions(
                controller.selectedConversationAgentId,
              ),
            ),
            loadMoreLabel: strings.scrollToLoadMoreHistories,
            loadingMoreLabel: strings.loadingMoreHistories,
            leading: ArchiveAgentConversationsButton(
              busy: controller.isCollectingConversationArchive,
              tooltip: strings.archiveAgentConversations,
              onPressed: () => unawaited(
                showConversationArchiveDialog(
                  context,
                  controller,
                  sourceAgentId: controller.selectedConversationAgentId,
                ),
              ),
            ),
            trailing: NewAgentConversationButton(
              enabled:
                  !controller.isLoadingConversations &&
                  !controller.isSendingConversationMessage,
              tooltip: strings.newConversation,
              onPressed: controller.startNewConversationSession,
            ),
          );
        }

        if (compact) {
          if (_historyCollapsed) {
            return chatPane;
          }
          final historyRatio = sessions.length > 1 ? 0.50 : 0.34;
          final historyMax = sessions.length > 1 ? 300.0 : 228.0;
          final historyMin = sessions.length > 1 ? 154.0 : 138.0;
          final historyHeight = (constraints.maxHeight * historyRatio).clamp(
            historyMin,
            historyMax,
          );
          final historyListHeight = (historyHeight - 58).clamp(72.0, 170.0);
          // The header, parity gate, and composer consume roughly 180 px. Keep
          // enough remaining height for the active timeline to render useful
          // content instead of collapsing to its padding at short window
          // heights. The existing outer scroll fallback preserves access to
          // both history and composer when both panes cannot fit at once.
          const minScrollableChatHeight = 300.0;
          final compactContentHeight =
              historyHeight + 8 + minScrollableChatHeight;
          if (constraints.maxHeight < compactContentHeight) {
            return SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    height: historyHeight,
                    child: historyPaneFor(historyListHeight.toDouble()),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(height: minScrollableChatHeight, child: chatPane),
                ],
              ),
            );
          }
          return Column(
            children: [
              SizedBox(
                height: historyHeight,
                child: historyPaneFor(historyListHeight.toDouble()),
              ),
              const SizedBox(height: 8),
              Expanded(child: chatPane),
            ],
          );
        }

        final historyListHeight = (constraints.maxHeight - 58).clamp(
          180.0,
          520.0,
        );
        final embeddedChatPane = AgentConversationActivePane(
          controller: controller,
          target: target,
          historyCollapsed: _historyCollapsed,
          onToggleHistory: _toggleHistoryCollapsed,
          collapseHistoryTooltip: strings.collapseHistoryConversations,
          expandHistoryTooltip: strings.expandHistoryConversations,
          framed: false,
        );
        return ResizableConversationSplit(
          historyPane: historyPaneFor(
            historyListHeight.toDouble(),
            framed: false,
            headerHeight: conversationHeaderHeight,
          ),
          chatPane: embeddedChatPane,
          initialHistoryWidth: conversationHistoryMinWidth,
          historyCollapsed: _historyCollapsed,
        );
      },
    );
  }
}
