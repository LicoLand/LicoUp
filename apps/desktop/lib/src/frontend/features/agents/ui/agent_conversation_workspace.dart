import 'dart:async';

import 'package:flutter/material.dart';

import 'package:flutter_client/src/application/controller/client_controller.dart';
import 'package:flutter_client/src/application/features/layout/layout_state_store.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_client/src/contracts/agent_conversation_models.dart';
import 'package:flutter_client/src/contracts/presentation/layout_state_namespace.dart';
import 'package:flutter_client/src/contracts/target_candidate.dart';
import 'package:flutter_client/src/frontend/layout/layout_destination_presentation.dart';
import 'package:flutter_client/src/frontend/layout/layout_focus_coordinator.dart';
import 'package:flutter_client/src/frontend/layout/layout_palette.dart';
import 'package:flutter_client/src/frontend/layout/layout_scope.dart';
import 'package:flutter_client/src/frontend/shared/ui/apple_popup_select.dart';
import 'package:flutter_client/src/frontend/shared/ui/lico_activity_animations.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/agent_render_adapter.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/agent_conversation_parity_disclosure.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/agent_orchestration_policy_controls.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/agent_usage_panel.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/agent_workspace_sidebar.dart';
import 'package:flutter_client/src/frontend/features/mcp_plugins/ui/mcp_plugins_panel.dart';
import 'package:flutter_client/src/frontend/features/skill_hub/ui/skill_hub_panel.dart';
import 'package:flutter_client/src/frontend/shared/platform/client_platform.dart';
import 'package:flutter_client/src/frontend/shared/ui/apple_glass.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/history_session_panel.dart';
import 'package:flutter_client/src/frontend/shared/ui/message_markdown.dart';
import 'package:flutter_client/src/frontend/shared/ui/panel_frame.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';

part 'agent_conversation_event_card.dart';
part 'agent_conversation_runtime_settings.dart';

const double _conversationHeaderHeight = 64;
const double _conversationHistoryMinWidth = 260;
const double _agentsSidebarMinWidth = 196;
const double _agentsSidebarMaxWidth = 420;
const double _agentsSidebarDividerWidth = 8;
const double _agentsFloatingMinChatWidth = 360;

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
  double _sidebarWidth = _agentsSidebarMinWidth;
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
        ? sidebar.extent.clamp(_agentsSidebarMinWidth, _agentsSidebarMaxWidth)
        : _agentsSidebarMinWidth;
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
      AgentsWorkspaceDestination.plugins => McpPluginsPanel(
        controller: widget.controller,
      ),
      AgentsWorkspaceDestination.skills => SkillHubPanel(
        controller: widget.controller,
      ),
      AgentsWorkspaceDestination.stats => AgentUsagePanel(
        controller: widget.controller,
      ),
      AgentsWorkspaceDestination.conversations =>
        target == null
            ? _DesktopNoAgentSelected(
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
                      _agentsSidebarDividerWidth -
                      _agentsFloatingMinChatWidth -
                      presentation.sidebarOuterHorizontalExtent -
                      presentation.detailOuterHorizontalExtent)
                  .clamp(_agentsSidebarMinWidth, _agentsSidebarMaxWidth)
                  .toDouble();
          final sidebarWidth = _sidebarWidth
              .clamp(_agentsSidebarMinWidth, maxSidebarWidth)
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
            onArchive: () =>
                unawaited(controller.archiveSelectedConversationAgent()),
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
                    child: _AgentsSidebarCollapseControl(
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
                    child: _AgentsSidebarCollapseControl(
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
                child: _PaneEdgeDragHandle(
                  dragHandleKey: const Key('agents-workspace-split-divider'),
                  width: _agentsSidebarDividerWidth,
                  enabled: !_historyCollapsed,
                  onDragDelta: (delta) {
                    setState(() {
                      _sidebarWidth = (sidebarWidth + delta)
                          .clamp(_agentsSidebarMinWidth, maxSidebarWidth)
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
          : _ActiveConversationPane(
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
            _MobileComposerSurface(
              child: _InactiveRuntimeMessageComposer(
                targetLabel: strings.agent,
              ),
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
              _InactiveRuntimeMessageComposer(targetLabel: strings.agent),
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
            meta: _sessionRelativeUpdatedAtLabel(session),
            preview: _messagePreviewText(session.preview),
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
      return _ActiveConversationPane(
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
        final chatPane = _ActiveConversationPane(
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
            leading: _ArchiveAgentConversationsButton(
              busy: controller.isCollectingConversationArchive,
              tooltip: strings.archiveAgentConversations,
              onPressed: () =>
                  unawaited(controller.archiveSelectedConversationAgent()),
            ),
            trailing: _NewAgentConversationButton(
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
        final embeddedChatPane = _ActiveConversationPane(
          controller: controller,
          target: target,
          historyCollapsed: _historyCollapsed,
          onToggleHistory: _toggleHistoryCollapsed,
          collapseHistoryTooltip: strings.collapseHistoryConversations,
          expandHistoryTooltip: strings.expandHistoryConversations,
          framed: false,
        );
        return _ResizableConversationSplit(
          historyPane: historyPaneFor(
            historyListHeight.toDouble(),
            framed: false,
            headerHeight: _conversationHeaderHeight,
          ),
          chatPane: embeddedChatPane,
          initialHistoryWidth: _conversationHistoryMinWidth,
          historyCollapsed: _historyCollapsed,
        );
      },
    );
  }
}

class _DesktopNoAgentSelected extends StatelessWidget {
  const _DesktopNoAgentSelected({
    required this.allowManualTargetActions,
    required this.onAddTarget,
  });

  final bool allowManualTargetActions;
  final VoidCallback onAddTarget;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.psychology_outlined, color: colors.textMuted, size: 28),
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
    );
  }
}

class _ArchiveAgentConversationsButton extends StatelessWidget {
  const _ArchiveAgentConversationsButton({
    required this.busy,
    required this.tooltip,
    required this.onPressed,
  });

  final bool busy;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return IconButton(
      tooltip: tooltip,
      onPressed: busy ? null : onPressed,
      color: colors.primary,
      disabledColor: colors.textMuted,
      hoverColor: Color.lerp(colors.surface, colors.primary, 0.12),
      style: IconButton.styleFrom(
        fixedSize: const Size(32, 32),
        minimumSize: const Size(32, 32),
        padding: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      icon: busy
          ? SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: colors.textMuted,
              ),
            )
          : const Icon(Icons.archive_outlined, size: 18),
    );
  }
}

class _NewAgentConversationButton extends StatelessWidget {
  const _NewAgentConversationButton({
    required this.enabled,
    required this.tooltip,
    required this.onPressed,
  });

  final bool enabled;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return IconButton(
      tooltip: tooltip,
      onPressed: enabled ? onPressed : null,
      color: colors.primary,
      disabledColor: colors.textMuted,
      hoverColor: Color.lerp(colors.surface, colors.primary, 0.12),
      style: IconButton.styleFrom(
        fixedSize: const Size(32, 32),
        minimumSize: const Size(32, 32),
        padding: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      icon: const Icon(Icons.add_comment_outlined, size: 18),
    );
  }
}

class _ActiveConversationPane extends StatelessWidget {
  const _ActiveConversationPane({
    required this.controller,
    required this.target,
    required this.historyCollapsed,
    required this.onToggleHistory,
    required this.collapseHistoryTooltip,
    required this.expandHistoryTooltip,
    this.framed = true,
    this.showSidebarToggle = true,
  });

  final ClientController controller;
  final TargetCandidate target;
  final bool historyCollapsed;
  final VoidCallback onToggleHistory;
  final String collapseHistoryTooltip;
  final String expandHistoryTooltip;
  final bool framed;
  final bool showSidebarToggle;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller.activeConversationListenable,
      builder: (context, _) => _ConversationPane(
        controller: controller,
        target: target,
        session: controller.selectedConversationSession,
        historyCollapsed: historyCollapsed,
        onToggleHistory: onToggleHistory,
        collapseHistoryTooltip: collapseHistoryTooltip,
        expandHistoryTooltip: expandHistoryTooltip,
        framed: framed,
        showSidebarToggle: showSidebarToggle,
      ),
    );
  }
}

class _ConversationPane extends StatelessWidget {
  const _ConversationPane({
    required this.controller,
    required this.target,
    required this.session,
    required this.historyCollapsed,
    required this.onToggleHistory,
    required this.collapseHistoryTooltip,
    required this.expandHistoryTooltip,
    this.framed = true,
    this.showSidebarToggle = true,
  });

  final ClientController controller;
  final TargetCandidate target;
  final AgentConversationSession? session;
  final bool historyCollapsed;
  final VoidCallback onToggleHistory;
  final String collapseHistoryTooltip;
  final String expandHistoryTooltip;
  final bool framed;
  final bool showSidebarToggle;

  @override
  Widget build(BuildContext context) {
    final mobileClient = isMobileClientPlatform(context);
    final strings = LicoStrings.of(context);
    final orchestrationSelected =
        controller.selectedConversationIsOrchestration;
    final composerEnabled = orchestrationSelected
        ? controller.agentOrchestrationPolicyConfigured &&
              controller.orchestrationAvailableTargets.isNotEmpty
        : target.canRelayRuntime;
    final gateReasonCode = orchestrationSelected
        ? (!controller.agentOrchestrationPolicyConfigured
              ? 'orchestration_policy_required'
              : 'orchestration_targets_unavailable')
        : (controller.lastError.trim().isNotEmpty
              ? controller.lastError.trim()
              : target.conversationSendGateReason);
    final gateCopy = conversationParityDisclosureCopy(
      strings: strings,
      reasonCode: gateReasonCode,
      orchestration:
          orchestrationSelected &&
          !composerEnabled &&
          !controller.agentOrchestrationPolicyConfigured,
    );
    final disabledHint = composerEnabled ? '' : gateCopy.reasonLabel;
    final composer = _RuntimeMessageComposer(
      targetLabel: target.label,
      initialDraft: controller.conversationComposerDraft,
      busy: controller.isSendingConversationMessage,
      enabled: composerEnabled,
      disabledHint: disabledHint,
      modelOptions: orchestrationSelected
          ? const []
          : controller.selectedConversationModelOptions,
      selectedModel: orchestrationSelected
          ? ''
          : controller.selectedConversationModel,
      reasoningEffortOptions: orchestrationSelected
          ? const []
          : controller.selectedConversationReasoningEffortOptions,
      selectedReasoningEffort: orchestrationSelected
          ? ''
          : controller.selectedConversationReasoningEffort,
      onModelChanged: controller.selectConversationModel,
      onReasoningEffortChanged: controller.selectConversationReasoningEffort,
      onDraftChanged: controller.updateConversationComposerDraft,
      onSend: (text) => unawaited(controller.sendConversationMessage(text)),
    );
    final sendGate = composerEnabled
        ? null
        : ConversationParitySendGateBanner(
            copy: gateCopy,
            onUnblock: switch (gateCopy.unblockAction) {
              ConversationParityUnblockAction.rescanAgents => () => unawaited(
                controller.scanTargets(),
              ),
              ConversationParityUnblockAction.editPolicy => () => unawaited(
                showAgentOrchestrationPolicyEditor(context, controller),
              ),
              null => null,
            },
          );
    if (mobileClient) {
      return Column(
        children: [
          if (!orchestrationSelected)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: ConversationParityDisclosurePanel(
                  target: target,
                  compact: true,
                ),
              ),
            ),
          Expanded(
            child: _MessageList(
              loading: controller.isLoadingConversations,
              session: session,
              target: target,
              turnActive: controller.isSendingConversationMessage,
              liveMessages: controller.selectedLiveConversationMessages,
            ),
          ),
          ?sendGate,
          _MobileComposerSurface(child: composer),
        ],
      );
    }
    final content = Column(
      children: [
        if (!mobileClient) ...[
          _ConversationHeader(
            controller: controller,
            target: target,
            session: session,
            historyCollapsed: historyCollapsed,
            onToggleHistory: onToggleHistory,
            collapseHistoryTooltip: collapseHistoryTooltip,
            expandHistoryTooltip: expandHistoryTooltip,
            showSidebarToggle: showSidebarToggle,
          ),
          const Divider(height: 1),
        ],
        Expanded(
          child: _MessageList(
            loading: controller.isLoadingConversations,
            session: session,
            target: target,
            turnActive: controller.isSendingConversationMessage,
            liveMessages: controller.selectedLiveConversationMessages,
          ),
        ),
        ?sendGate,
        const Divider(height: 1),
        composer,
      ],
    );
    if (!framed) {
      return content;
    }
    return PanelFrame(child: content);
  }
}

class _ResizableConversationSplit extends StatefulWidget {
  const _ResizableConversationSplit({
    required this.historyPane,
    required this.chatPane,
    required this.initialHistoryWidth,
    required this.historyCollapsed,
  });

  final Widget historyPane;
  final Widget chatPane;
  final double initialHistoryWidth;
  final bool historyCollapsed;

  @override
  State<_ResizableConversationSplit> createState() =>
      _ResizableConversationSplitState();
}

class _ResizableConversationSplitState
    extends State<_ResizableConversationSplit> {
  static const double _minChatWidth = 360;
  static const double _dragHandleWidth = 12;

  double? _historyWidth;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxHistoryWidth =
            (constraints.maxWidth - _dragHandleWidth - _minChatWidth)
                .clamp(_conversationHistoryMinWidth, constraints.maxWidth)
                .toDouble();
        final historyWidth = (_historyWidth ?? widget.initialHistoryWidth)
            .clamp(_conversationHistoryMinWidth, maxHistoryWidth)
            .toDouble();
        return ColoredBox(
          key: const Key('conversation-split-page'),
          color: colors.surface,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!widget.historyCollapsed)
                SizedBox(width: historyWidth, child: widget.historyPane),
              Expanded(
                child: _PaneEdgeDragHandle(
                  width: _dragHandleWidth,
                  enabled: !widget.historyCollapsed,
                  onDragDelta: (delta) {
                    setState(() {
                      _historyWidth = (historyWidth + delta)
                          .clamp(_conversationHistoryMinWidth, maxHistoryWidth)
                          .toDouble();
                    });
                  },
                  child: widget.chatPane,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _PaneEdgeDragHandle extends StatelessWidget {
  const _PaneEdgeDragHandle({
    this.dragHandleKey,
    required this.width,
    required this.onDragDelta,
    required this.child,
    this.enabled = true,
  });

  final Key? dragHandleKey;
  final double width;
  final ValueChanged<double> onDragDelta;
  final Widget child;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    if (!enabled) {
      return child;
    }
    return Stack(
      children: [
        child,
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          child: MouseRegion(
            cursor: SystemMouseCursors.resizeLeftRight,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onHorizontalDragUpdate: (details) =>
                  onDragDelta(details.delta.dx),
              child: SizedBox(key: dragHandleKey, width: width),
            ),
          ),
        ),
      ],
    );
  }
}

class _MobileComposerSurface extends StatelessWidget {
  const _MobileComposerSurface({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: colors.line)),
      ),
      child: child,
    );
  }
}

class _OpencodeServeStatusChip extends StatelessWidget {
  const _OpencodeServeStatusChip({required this.state});

  final Map<String, dynamic>? state;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final status = (state?['status'] as String?)?.trim() ?? 'stopped';
    final port = state?['port'];
    final conflict = state?['portConflict'] == true;
    final label = switch (status) {
      'running' => port == null ? 'OpenCode serve' : 'OpenCode :$port',
      'blocked' => conflict ? 'OpenCode port blocked' : 'OpenCode blocked',
      'unavailable' => 'OpenCode unavailable',
      _ => 'OpenCode stopped',
    };
    final color = switch (status) {
      'running' => colors.success,
      'blocked' || 'unavailable' => colors.error,
      _ => colors.textMuted,
    };
    return Container(
      key: const Key('opencode-serve-status'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _ConversationHeader extends StatelessWidget {
  const _ConversationHeader({
    required this.controller,
    required this.target,
    required this.session,
    required this.historyCollapsed,
    required this.onToggleHistory,
    required this.collapseHistoryTooltip,
    required this.expandHistoryTooltip,
    this.showSidebarToggle = true,
  });

  final ClientController controller;
  final TargetCandidate target;
  final AgentConversationSession? session;
  final bool historyCollapsed;
  final VoidCallback onToggleHistory;
  final String collapseHistoryTooltip;
  final String expandHistoryTooltip;
  final bool showSidebarToggle;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final sessionTitle = session?.title.trim();
    final headerTitle = sessionTitle == null || sessionTitle.isEmpty
        ? target.label
        : sessionTitle;
    return LayoutBuilder(
      builder: (context, constraints) {
        final mobileClient = isMobileClientPlatform(context);
        final identity = Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: mobileClient
              ? const <Widget>[]
              : [
                  if (showSidebarToggle) ...[
                    IconButton(
                      tooltip: historyCollapsed
                          ? expandHistoryTooltip
                          : collapseHistoryTooltip,
                      onPressed: onToggleHistory,
                      color: colors.primary,
                      hoverColor: Color.lerp(
                        colors.surface,
                        colors.primary,
                        0.12,
                      ),
                      style: IconButton.styleFrom(
                        fixedSize: const Size(40, 40),
                        minimumSize: const Size(40, 40),
                        padding: EdgeInsets.zero,
                        shape: const CircleBorder(),
                      ),
                      icon: _SidebarToggleGlyph(
                        expanded: !historyCollapsed,
                        color: colors.primary,
                      ),
                    ),
                    const SizedBox(width: 12),
                  ],
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        headerTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.text,
                          fontWeight: FontWeight.w800,
                          fontSize: 16,
                        ),
                      ),
                    ),
                  ),
                  if (!controller.selectedConversationIsOrchestration) ...[
                    const SizedBox(width: 10),
                    ConversationParityDisclosurePanel(target: target),
                  ],
                  if (target.target == 'opencode') ...[
                    const SizedBox(width: 8),
                    _OpencodeServeStatusChip(
                      state: controller.opencodeServeState,
                    ),
                  ],
                  if (controller.selectedConversationIsOrchestration) ...[
                    const SizedBox(width: 12),
                    AgentOrchestrationPolicyHeaderControls(
                      controller: controller,
                    ),
                  ],
                ],
        );

        final content = Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: identity,
        );
        if (mobileClient) {
          return content;
        }
        return SizedBox(height: _conversationHeaderHeight, child: content);
      },
    );
  }
}

class _AgentsSidebarCollapseControl extends StatefulWidget {
  const _AgentsSidebarCollapseControl({
    super.key,
    required this.expanded,
    required this.tooltip,
    required this.onPressed,
  });

  final bool expanded;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  State<_AgentsSidebarCollapseControl> createState() =>
      _AgentsSidebarCollapseControlState();
}

class _AgentsSidebarCollapseControlState
    extends State<_AgentsSidebarCollapseControl> {
  bool _hovered = false;
  bool _pressed = false;

  static const double _hitSize = 32;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final iconColor = colors.text.withAlpha(220);
    final showCircle = _hovered || _pressed;
    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() {
          _hovered = false;
          _pressed = false;
        }),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) {
            setState(() => _pressed = false);
            widget.onPressed();
          },
          onTapCancel: () => setState(() => _pressed = false),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            width: _hitSize,
            height: _hitSize,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: showCircle
                  ? colors.surface.withAlpha(colors.isDark ? 160 : 220)
                  : Colors.transparent,
              border: showCircle
                  ? Border.all(color: colors.line.withAlpha(110))
                  : null,
            ),
            child: _SidebarToggleGlyph(
              expanded: widget.expanded,
              color: iconColor,
            ),
          ),
        ),
      ),
    );
  }
}

class _SidebarToggleGlyph extends StatelessWidget {
  const _SidebarToggleGlyph({required this.expanded, required this.color});

  final bool expanded;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size(22, 22),
      painter: _SidebarToggleGlyphPainter(expanded: expanded, color: color),
    );
  }
}

class _SidebarToggleGlyphPainter extends CustomPainter {
  const _SidebarToggleGlyphPainter({
    required this.expanded,
    required this.color,
  });

  final bool expanded;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final outerRect = Rect.fromLTWH(3, 4, size.width - 6, size.height - 8);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final fill = Paint()
      ..color = color.withAlpha(76)
      ..style = PaintingStyle.fill;
    final outer = RRect.fromRectAndRadius(
      outerRect,
      const Radius.circular(2.5),
    );
    canvas.drawRRect(outer, stroke);

    final panelWidth = outerRect.width * 0.4;
    final panelRect = expanded
        ? Rect.fromLTWH(
            outerRect.left,
            outerRect.top,
            panelWidth,
            outerRect.height,
          )
        : Rect.fromLTWH(
            outerRect.right - panelWidth,
            outerRect.top,
            panelWidth,
            outerRect.height,
          );
    canvas.drawRRect(
      RRect.fromRectAndRadius(panelRect.deflate(1.8), const Radius.circular(1)),
      fill,
    );
    final dividerX = expanded ? panelRect.right : panelRect.left;
    canvas.drawLine(
      Offset(dividerX, outerRect.top + 1.5),
      Offset(dividerX, outerRect.bottom - 1.5),
      stroke,
    );
  }

  @override
  bool shouldRepaint(_SidebarToggleGlyphPainter oldDelegate) {
    return oldDelegate.expanded != expanded || oldDelegate.color != color;
  }
}

class _MessageList extends StatefulWidget {
  const _MessageList({
    required this.loading,
    required this.session,
    required this.target,
    this.turnActive = false,
    this.liveMessages = const [],
  });

  final bool loading;
  final AgentConversationSession? session;
  final TargetCandidate target;
  final bool turnActive;
  final List<AgentConversationMessage> liveMessages;

  @override
  State<_MessageList> createState() => _MessageListState();
}

class _MessageListState extends State<_MessageList> {
  bool _showDiagnostics = false;
  late Future<AgentRenderAdapter> _adapterFuture;
  (AgentRenderAdapterRegistry, String, String, String, String)?
  _adapterResolutionKey;
  AgentConversationSession? _timelineSession;
  List<AgentConversationMessage>? _timelineLiveMessages;
  String _timelineSessionIdentity = '';
  String _timelineSessionKey = '';
  List<_ConversationTimelineItem> _timelineItems = const [];
  Map<String, int> _timelineIndexByStorageKey = const {};
  List<AgentSemanticArtifactRef> _artifacts = const [];
  int _footerCount = 0;
  String _activeProcessStorageKey = '';

  @override
  void initState() {
    super.initState();
    _syncAdapterFuture();
    _syncTimelineCache();
    _syncActiveProcessStorageKey();
  }

  @override
  void didUpdateWidget(covariant _MessageList oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncAdapterFuture();
    final timelineChanged = _syncTimelineCache();
    if (timelineChanged || oldWidget.turnActive != widget.turnActive) {
      _syncActiveProcessStorageKey();
    }
  }

  void _syncAdapterFuture() {
    final registry = AgentRenderAdapterRegistry.instance;
    final session = widget.session;
    final nextKey = (
      registry,
      widget.target.target,
      session?.sourceClient ?? '',
      session?.sourceTool ?? '',
      session?.adapterId ?? '',
    );
    if (_adapterResolutionKey == nextKey) {
      return;
    }
    _adapterResolutionKey = nextKey;
    _adapterFuture = registry.resolve(
      agentId: nextKey.$2,
      sourceClient: nextKey.$3,
      sourceTool: nextKey.$4,
      adapterId: nextKey.$5,
    );
  }

  bool _syncTimelineCache() {
    final session = widget.session;
    final sessionIdentity = [
      widget.target.target,
      session?.id ?? '',
      session?.nativeSessionId ?? '',
    ].join('|');
    if (identical(_timelineSession, session) &&
        identical(_timelineLiveMessages, widget.liveMessages) &&
        _timelineSessionIdentity == sessionIdentity) {
      return false;
    }

    final messages = <AgentConversationMessage>[
      ...?session?.messages,
      ...widget.liveMessages,
    ];
    final timelineItems = _conversationTimelineItems(
      messages,
      sessionIdentity,
      historyTruncated: session?.historyTruncated ?? false,
      messageTreeTruncated: session?.messageTreeTruncated ?? false,
    ).reversed.toList(growable: false);
    final artifacts = session?.artifacts ?? const <AgentSemanticArtifactRef>[];
    final hasDiagnostics = session?.hasDiagnostics ?? false;
    final footerCount =
        (artifacts.isNotEmpty ? 1 : 0) + (hasDiagnostics ? 1 : 0);
    final indexByStorageKey = <String, int>{};
    var footerIndex = 0;
    if (hasDiagnostics) {
      indexByStorageKey['conversation-diagnostics'] = footerIndex;
      footerIndex += 1;
    }
    if (artifacts.isNotEmpty) {
      indexByStorageKey['conversation-artifacts'] = footerIndex;
    }
    for (var index = 0; index < timelineItems.length; index += 1) {
      indexByStorageKey[timelineItems[index].storageKey] = index + footerCount;
    }

    _timelineSession = session;
    _timelineLiveMessages = widget.liveMessages;
    _timelineSessionIdentity = sessionIdentity;
    _timelineSessionKey = sessionIdentity.hashCode
        .toUnsigned(32)
        .toRadixString(16);
    _timelineItems = timelineItems;
    _timelineIndexByStorageKey = Map<String, int>.unmodifiable(
      indexByStorageKey,
    );
    _artifacts = artifacts;
    _footerCount = footerCount;
    return true;
  }

  void _syncActiveProcessStorageKey() {
    _activeProcessStorageKey = '';
    if (!widget.turnActive) {
      return;
    }
    for (final item in _timelineItems) {
      if (item is _ConversationProcessTimelineItem) {
        _activeProcessStorageKey = item.storageKey;
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final session = widget.session;
    final messages = <AgentConversationMessage>[
      ...?session?.messages,
      ...widget.liveMessages,
    ];
    if (widget.loading && messages.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (messages.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Text(
            strings.noMessagesInHistory,
            textAlign: TextAlign.center,
            style: TextStyle(color: colors.textMuted),
          ),
        ),
      );
    }
    return FutureBuilder<AgentRenderAdapter>(
      future: _adapterFuture,
      builder: (context, snapshot) {
        final adapter = snapshot.data ?? AgentRenderAdapter.fallback();
        return ListView.builder(
          key: PageStorageKey<String>(
            'agent-conversation-message-list-$_timelineSessionKey',
          ),
          reverse: true,
          padding: EdgeInsets.fromLTRB(
            16,
            16,
            16,
            16 + adapter.assistantVerticalPadding,
          ),
          findChildIndexCallback: (key) {
            if (key case ValueKey<String>(:final value)) {
              return _timelineIndexByStorageKey[value];
            }
            return null;
          },
          itemBuilder: (context, index) {
            if (index < _footerCount) {
              if (session?.hasDiagnostics ?? false) {
                if (index == 0) {
                  return Padding(
                    key: const ValueKey<String>('conversation-diagnostics'),
                    padding: EdgeInsets.only(
                      bottom: adapter.assistantVerticalPadding,
                    ),
                    child: _ConversationDiagnosticsPanel(
                      session: session!,
                      expanded: _showDiagnostics,
                      onToggle: () {
                        setState(() {
                          _showDiagnostics = !_showDiagnostics;
                        });
                      },
                    ),
                  );
                }
                if (_artifacts.isNotEmpty && index == 1) {
                  return Padding(
                    key: const ValueKey<String>('conversation-artifacts'),
                    padding: EdgeInsets.only(
                      bottom: adapter.assistantVerticalPadding,
                    ),
                    child: _ConversationArtifactsPanel(artifacts: _artifacts),
                  );
                }
              } else if (_artifacts.isNotEmpty && index == 0) {
                return Padding(
                  key: const ValueKey<String>('conversation-artifacts'),
                  padding: EdgeInsets.only(
                    bottom: adapter.assistantVerticalPadding,
                  ),
                  child: _ConversationArtifactsPanel(artifacts: _artifacts),
                );
              }
            }
            final item = _timelineItems[index - _footerCount];
            final content = switch (item) {
              _ConversationMessageTimelineItem(:final message) => _MessageBlock(
                message: message,
                adapter: adapter,
              ),
              _ConversationProcessTimelineItem(:final events) =>
                _ConversationProcessCard(
                  events: events,
                  adapter: adapter,
                  active: item.storageKey == _activeProcessStorageKey,
                ),
              _ConversationTruncationTimelineItem(
                :final historyTruncated,
                :final messageTreeTruncated,
              ) =>
                _ConversationTruncationNotice(
                  historyTruncated: historyTruncated,
                  messageTreeTruncated: messageTreeTruncated,
                ),
            };
            return Padding(
              key: ValueKey<String>(item.storageKey),
              padding: EdgeInsets.only(
                bottom: index + 1 < _timelineItems.length + _footerCount
                    ? adapter.assistantVerticalPadding
                    : 0,
              ),
              child: content,
            );
          },
          itemCount: _timelineItems.length + _footerCount,
        );
      },
    );
  }
}

class _ConversationArtifactsPanel extends StatelessWidget {
  const _ConversationArtifactsPanel({required this.artifacts});

  final List<AgentSemanticArtifactRef> artifacts;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: colors.line.withAlpha(80)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Artifacts', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            for (final artifact in artifacts)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  '${artifact.label} (${artifact.kind})'
                  '${artifact.ref.isEmpty ? '' : ' → ${artifact.ref}'}',
                  style: TextStyle(color: colors.textMuted, fontSize: 13),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ConversationDiagnosticsPanel extends StatelessWidget {
  const _ConversationDiagnosticsPanel({
    required this.session,
    required this.expanded,
    required this.onToggle,
  });

  final AgentConversationSession session;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final semantic = session.semantic;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: colors.line.withAlpha(80)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: onToggle,
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Diagnostics',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  Icon(
                    expanded ? Icons.expand_less : Icons.expand_more,
                    color: colors.textMuted,
                  ),
                ],
              ),
            ),
          ),
          if (expanded && semantic != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Audit',
                    style: TextStyle(
                      color: colors.textMuted,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Adapter: ${semantic.audit.adapterId}\n'
                    'Host: ${semantic.audit.hostApp}\n'
                    'Source: ${semantic.audit.sourceKind}\n'
                    'Session: ${semantic.audit.nativeSessionId}\n'
                    'Redaction: ${semantic.audit.redactionStatus}\n'
                    'Validation: ${semantic.audit.validationStatus}\n'
                    'Evidence: ${semantic.audit.sourceEvidence.pathRef}',
                    style: TextStyle(color: colors.textMuted, fontSize: 12),
                  ),
                  if (semantic.audit.parseWarnings.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Parse warnings: ${semantic.audit.parseWarnings.join('; ')}',
                      style: TextStyle(color: colors.textMuted, fontSize: 12),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Text(
                    'Raw evidence',
                    style: TextStyle(
                      color: colors.textMuted,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  for (final evidence in semantic.rawEvidence)
                    Text(
                      '${evidence.kind}: ${evidence.pathRef} (${evidence.contentHash})',
                      style: TextStyle(color: colors.textMuted, fontSize: 12),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _MessageBlock extends StatelessWidget {
  const _MessageBlock({required this.message, required this.adapter});

  final AgentConversationMessage message;
  final AgentRenderAdapter adapter;

  @override
  Widget build(BuildContext context) {
    if (message.isSubagentCard) {
      return _SubagentCardBlock(message: message, adapter: adapter);
    }
    return switch (message.kind) {
      AgentConversationMessageKind.user => _UserMessageBlock(
        message: message,
        adapter: adapter,
      ),
      AgentConversationMessageKind.assistant =>
        adapter.assistantLayout == AgentAssistantLayout.bubble
            ? _AssistantBubbleBlock(message: message, adapter: adapter)
            : _AssistantDocumentBlock(message: message, adapter: adapter),
      AgentConversationMessageKind.toolCall ||
      AgentConversationMessageKind.toolResult ||
      AgentConversationMessageKind.reasoning ||
      AgentConversationMessageKind.metadata ||
      AgentConversationMessageKind.error ||
      AgentConversationMessageKind.event => throw StateError(
        'Structured events must be rendered by the process timeline.',
      ),
      AgentConversationMessageKind.subagent => _SubagentCardBlock(
        message: message,
        adapter: adapter,
      ),
    };
  }
}

class _SubagentCardBlock extends StatefulWidget {
  const _SubagentCardBlock({required this.message, required this.adapter});

  final AgentConversationMessage message;
  final AgentRenderAdapter adapter;

  @override
  State<_SubagentCardBlock> createState() => _SubagentCardBlockState();
}

class _SubagentCardBlockState extends State<_SubagentCardBlock> {
  late bool _expanded = !widget.message.collapsed;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final title = widget.message.cardTitle.trim().isEmpty
        ? strings.subagentTask
        : widget.message.cardTitle.trim();
    final subtitle = widget.message.cardSubtitle.trim().isEmpty
        ? '${strings.subagentTask} · ${strings.messagesCount(widget.message.childMessages.length)}'
        : widget.message.cardSubtitle.trim();
    final preview = _messagePreviewText(widget.message.text);
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: widget.adapter.assistantMaxWidth),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.white.withAlpha(colors.isDark ? 18 : 24),
            borderRadius: BorderRadius.circular(
              AppleControlMetrics.menuCornerRadius,
            ),
            border: Border.all(
              color: Colors.white.withAlpha(colors.isDark ? 48 : 70),
              width: AppleControlMetrics.hairline,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              InkWell(
                borderRadius: BorderRadius.circular(
                  AppleControlMetrics.menuCornerRadius,
                ),
                onTap: () => setState(() => _expanded = !_expanded),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.account_tree_outlined,
                        color: colors.info.withAlpha(200),
                        size: 18,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: colors.text,
                                fontWeight: FontWeight.w600,
                                fontSize: 13,
                                letterSpacing: -0.08,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: colors.textMuted,
                                fontSize: 11.5,
                                fontWeight: FontWeight.w400,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Icon(
                        _expanded
                            ? Icons.keyboard_arrow_up_rounded
                            : Icons.keyboard_arrow_down_rounded,
                        color: colors.textMuted,
                        size: 18,
                      ),
                    ],
                  ),
                ),
              ),
              if (!_expanded && preview.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(44, 0, 14, 12),
                  child: Text(
                    preview,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.textMuted,
                      fontSize: 12,
                      height: 1.35,
                    ),
                  ),
                ),
              ],
              if (_expanded) ...[
                Divider(height: 1, color: colors.line),
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (
                        var index = 0;
                        index < widget.message.childMessages.length;
                        index++
                      ) ...[
                        _SubagentChildMessageBlock(
                          message: widget.message.childMessages[index],
                          adapter: widget.adapter,
                        ),
                        if (index != widget.message.childMessages.length - 1)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            child: Divider(height: 1, color: colors.line),
                          ),
                      ],
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _MessageContent extends StatelessWidget {
  const _MessageContent({
    required this.data,
    required this.foreground,
    required this.accent,
    required this.codeBackground,
    required this.blockBackground,
    required this.borderColor,
    required this.renderStyle,
  });

  final String data;
  final Color foreground;
  final Color accent;
  final Color codeBackground;
  final Color blockBackground;
  final Color borderColor;
  final MessageMarkdownStyle renderStyle;

  @override
  Widget build(BuildContext context) {
    final display = splitMessageDisplayBlocks(data);
    final hasBody = display.body.trim().isNotEmpty;
    final hasDetails = display.metadataBlocks.isNotEmpty;
    final hasRecommendedPlugins = display.recommendedPluginsBlocks.isNotEmpty;
    if (!hasBody && !hasDetails && !hasRecommendedPlugins) {
      return MessageMarkdown(
        data: '',
        foreground: foreground,
        accent: accent,
        codeBackground: codeBackground,
        blockBackground: blockBackground,
        borderColor: borderColor,
        renderStyle: renderStyle,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (hasBody)
          MessageMarkdown(
            data: display.body,
            foreground: foreground,
            accent: accent,
            codeBackground: codeBackground,
            blockBackground: blockBackground,
            borderColor: borderColor,
            renderStyle: renderStyle,
          ),
        if (hasRecommendedPlugins) ...[
          if (hasBody) SizedBox(height: renderStyle.blockSpacing),
          _RecommendedPluginsDisclosure(
            blocks: display.recommendedPluginsBlocks,
            accent: accent,
            codeBackground: codeBackground,
            blockBackground: blockBackground,
            borderColor: borderColor,
            renderStyle: renderStyle,
          ),
        ],
        if (hasDetails) ...[
          if (hasBody || hasRecommendedPlugins)
            SizedBox(height: renderStyle.blockSpacing),
          _MessageDetailsDisclosure(
            details: display.metadataBlocks.join('\n\n'),
            detailsCount: display.metadataBlocks.length,
            accent: accent,
            codeBackground: codeBackground,
            blockBackground: blockBackground,
            borderColor: borderColor,
            renderStyle: renderStyle,
          ),
        ],
      ],
    );
  }
}

class _MessageDetailsDisclosure extends StatefulWidget {
  const _MessageDetailsDisclosure({
    required this.details,
    required this.detailsCount,
    required this.accent,
    required this.codeBackground,
    required this.blockBackground,
    required this.borderColor,
    required this.renderStyle,
  });

  final String details;
  final int detailsCount;
  final Color accent;
  final Color codeBackground;
  final Color blockBackground;
  final Color borderColor;
  final MessageMarkdownStyle renderStyle;

  @override
  State<_MessageDetailsDisclosure> createState() =>
      _MessageDetailsDisclosureState();
}

class _MessageDetailsDisclosureState extends State<_MessageDetailsDisclosure> {
  var _expanded = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final title = strings.details;
    final countSuffix = widget.detailsCount > 1
        ? ' · ${widget.detailsCount}'
        : '';
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(colors.isDark ? 12 : 16),
        borderRadius: BorderRadius.circular(
          AppleControlMetrics.controlCornerRadius,
        ),
        border: Border.all(
          color: Colors.white.withAlpha(colors.isDark ? 36 : 56),
          width: AppleControlMetrics.hairline,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(
              AppleControlMetrics.controlCornerRadius,
            ),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _expanded
                        ? Icons.keyboard_arrow_down_rounded
                        : Icons.keyboard_arrow_right_rounded,
                    size: 15,
                    color: colors.textMuted,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '$title$countSuffix',
                    style: TextStyle(
                      color: colors.textMuted,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      letterSpacing: -0.04,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_expanded) ...[
            Divider(
              height: 1,
              color: Colors.white.withAlpha(colors.isDark ? 28 : 48),
            ),
            Padding(
              padding: const EdgeInsets.all(10),
              child: MessageMarkdown(
                data: widget.details,
                foreground: colors.textMuted,
                accent: colors.info,
                codeBackground: widget.codeBackground,
                blockBackground: widget.blockBackground,
                borderColor: Colors.white.withAlpha(colors.isDark ? 36 : 56),
                renderStyle: widget.renderStyle,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _RecommendedPluginsDisclosure extends StatefulWidget {
  const _RecommendedPluginsDisclosure({
    required this.blocks,
    required this.accent,
    required this.codeBackground,
    required this.blockBackground,
    required this.borderColor,
    required this.renderStyle,
  });

  final List<String> blocks;
  final Color accent;
  final Color codeBackground;
  final Color blockBackground;
  final Color borderColor;
  final MessageMarkdownStyle renderStyle;

  @override
  State<_RecommendedPluginsDisclosure> createState() =>
      _RecommendedPluginsDisclosureState();
}

class _RecommendedPluginsDisclosureState
    extends State<_RecommendedPluginsDisclosure> {
  var _expanded = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final title = strings.recommendedPlugins;
    final pluginCount = recommendedPluginsCount(widget.blocks);
    final countSuffix = pluginCount > 0 ? ' · $pluginCount' : '';
    final content = widget.blocks.join('\n\n');
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(colors.isDark ? 12 : 16),
        borderRadius: BorderRadius.circular(
          AppleControlMetrics.controlCornerRadius,
        ),
        border: Border.all(
          color: Colors.white.withAlpha(colors.isDark ? 36 : 56),
          width: AppleControlMetrics.hairline,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(
              AppleControlMetrics.controlCornerRadius,
            ),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _expanded
                        ? Icons.keyboard_arrow_down_rounded
                        : Icons.keyboard_arrow_right_rounded,
                    size: 15,
                    color: colors.textMuted,
                  ),
                  const SizedBox(width: 6),
                  Icon(
                    Icons.extension_outlined,
                    size: 13,
                    color: colors.textMuted,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '$title$countSuffix',
                      style: TextStyle(
                        color: colors.textMuted,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        letterSpacing: -0.04,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_expanded) ...[
            Divider(
              height: 1,
              color: Colors.white.withAlpha(colors.isDark ? 28 : 48),
            ),
            Padding(
              padding: const EdgeInsets.all(10),
              child: MessageMarkdown(
                data: content,
                foreground: colors.text,
                accent: colors.info,
                codeBackground: widget.codeBackground,
                blockBackground: widget.blockBackground,
                borderColor: Colors.white.withAlpha(colors.isDark ? 36 : 56),
                renderStyle: widget.renderStyle,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

@visibleForTesting
int recommendedPluginsCount(List<String> blocks) {
  var count = 0;
  for (final block in blocks) {
    for (final line in block.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.startsWith('- ') || trimmed.startsWith('* ')) {
        count++;
      }
    }
  }
  return count;
}

@visibleForTesting
class MessageDisplayContent {
  const MessageDisplayContent({
    required this.body,
    required this.metadataBlocks,
    required this.recommendedPluginsBlocks,
  });

  final String body;
  final List<String> metadataBlocks;
  final List<String> recommendedPluginsBlocks;
}

@visibleForTesting
MessageDisplayContent splitMessageDisplayBlocks(String data) {
  final pluginsExtraction = _extractBlocks(data, _recommendedPluginsPattern);
  final metadataExtraction = _extractBlocks(
    pluginsExtraction.body,
    _additionalMetadataPattern,
  );
  return MessageDisplayContent(
    body: _compactMessageBody(metadataExtraction.body),
    metadataBlocks: metadataExtraction.blocks,
    recommendedPluginsBlocks: pluginsExtraction.blocks,
  );
}

({String body, List<String> blocks}) _extractBlocks(
  String data,
  RegExp pattern,
) {
  final matches = pattern.allMatches(data);
  if (matches.isEmpty) {
    return (body: data, blocks: const <String>[]);
  }
  final body = StringBuffer();
  final blocks = <String>[];
  var cursor = 0;
  for (final match in matches) {
    body.write(data.substring(cursor, match.start));
    final block = (match.group(1) ?? '').trim();
    if (block.isNotEmpty) {
      blocks.add(block);
    }
    cursor = match.end;
  }
  body.write(data.substring(cursor));
  return (body: body.toString(), blocks: blocks);
}

final _additionalMetadataPattern = RegExp(
  r'<\s*additional_metadata\s*>([\s\S]*?)<\s*/\s*additional_metadata\s*>',
  caseSensitive: false,
);

final _recommendedPluginsPattern = RegExp(
  r'<\s*recommended_plugins\s*>([\s\S]*?)<\s*/\s*recommended_plugins\s*>',
  caseSensitive: false,
);

String _compactMessageBody(String text) {
  return text
      .replaceAll(RegExp(r'[ \t]+\n'), '\n')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
}

String _messagePreviewText(String text) {
  return splitMessageDisplayBlocks(text).body.trim();
}

class _SubagentChildMessageBlock extends StatelessWidget {
  const _SubagentChildMessageBlock({
    required this.message,
    required this.adapter,
  });

  final AgentConversationMessage message;
  final AgentRenderAdapter adapter;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return _MessageContent(
      data: message.text,
      foreground: _messageForeground(colors, message.role),
      accent: colors.primary,
      codeBackground: _toneColor(colors, adapter.codeTone),
      blockBackground: _toneColor(colors, adapter.quoteTone),
      borderColor: colors.line,
      renderStyle: adapter.markdownStyle,
    );
  }
}

class _UserMessageBlock extends StatelessWidget {
  const _UserMessageBlock({required this.message, required this.adapter});

  final AgentConversationMessage message;
  final AgentRenderAdapter adapter;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    return Align(
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: adapter.userBubble.maxWidth),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: _bubbleColor(colors, adapter.userBubble.tone),
            borderRadius: BorderRadius.circular(adapter.userBubble.radius),
            border: Border.all(color: _bubbleBorderColor(colors)),
          ),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: adapter.userBubble.paddingX,
              vertical: adapter.userBubble.paddingY,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (adapter.showUserRoleLabel) ...[
                  Text(
                    strings.you,
                    style: TextStyle(
                      color: colors.textMuted,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                ],
                _MessageContent(
                  data: message.text,
                  foreground: colors.text,
                  accent: colors.primary,
                  codeBackground: _toneColor(colors, 'subtle'),
                  blockBackground: _toneColor(colors, 'surface'),
                  borderColor: colors.line,
                  renderStyle: adapter.markdownStyle,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AssistantDocumentBlock extends StatelessWidget {
  const _AssistantDocumentBlock({required this.message, required this.adapter});

  final AgentConversationMessage message;
  final AgentRenderAdapter adapter;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: adapter.assistantMaxWidth),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: adapter.assistantHorizontalInset,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (adapter.showAssistantRoleLabel) ...[
                Text(
                  strings.agent,
                  style: TextStyle(
                    color: colors.textMuted,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
              ],
              _MessageContent(
                data: message.text,
                foreground: _messageForeground(colors, message.role),
                accent: colors.primary,
                codeBackground: _toneColor(colors, adapter.codeTone),
                blockBackground: _toneColor(colors, adapter.quoteTone),
                borderColor: colors.line,
                renderStyle: adapter.markdownStyle,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AssistantBubbleBlock extends StatelessWidget {
  const _AssistantBubbleBlock({required this.message, required this.adapter});

  final AgentConversationMessage message;
  final AgentRenderAdapter adapter;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: adapter.assistantMaxWidth),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colors.surfaceLow,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: colors.line),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: _MessageContent(
              data: message.text,
              foreground: _messageForeground(colors, message.role),
              accent: colors.primary,
              codeBackground: _toneColor(colors, adapter.codeTone),
              blockBackground: _toneColor(colors, adapter.quoteTone),
              borderColor: colors.line,
              renderStyle: adapter.markdownStyle,
            ),
          ),
        ),
      ),
    );
  }
}

Color _messageForeground(LicoThemeColors colors, String role) {
  final normalized = role.toLowerCase();
  if (normalized == 'metadata' || normalized == 'system') {
    return colors.textMuted;
  }
  return colors.text;
}

Color _bubbleColor(LicoThemeColors colors, String tone) {
  return switch (tone) {
    'primary' => colors.primary,
    'subtle' => colors.surfaceLow,
    'raised' => colors.surface,
    _ => colors.surfaceLow,
  };
}

Color _bubbleBorderColor(LicoThemeColors colors) {
  return colors.line;
}

Color _toneColor(LicoThemeColors colors, String tone) {
  return switch (tone) {
    'raised' => colors.surfaceHigh,
    'surface' => colors.surface,
    'muted' => colors.surfaceHighest,
    _ => colors.surfaceLow,
  };
}

class _RuntimeMessageComposer extends StatefulWidget {
  const _RuntimeMessageComposer({
    required this.targetLabel,
    required this.initialDraft,
    required this.busy,
    required this.enabled,
    required this.disabledHint,
    required this.modelOptions,
    required this.selectedModel,
    required this.reasoningEffortOptions,
    required this.selectedReasoningEffort,
    required this.onModelChanged,
    required this.onReasoningEffortChanged,
    required this.onDraftChanged,
    required this.onSend,
  });

  final String targetLabel;
  final String initialDraft;
  final bool busy;
  final bool enabled;
  final String disabledHint;
  final List<String> modelOptions;
  final String selectedModel;
  final List<String> reasoningEffortOptions;
  final String selectedReasoningEffort;
  final ValueChanged<String> onModelChanged;
  final ValueChanged<String> onReasoningEffortChanged;
  final ValueChanged<String> onDraftChanged;
  final ValueChanged<String> onSend;

  @override
  State<_RuntimeMessageComposer> createState() =>
      _RuntimeMessageComposerState();
}

class _RuntimeMessageComposerState extends State<_RuntimeMessageComposer> {
  late final TextEditingController _controller;
  final FocusNode _focusNode = FocusNode();
  LayoutFocusCoordinator? _layoutFocusCoordinator;
  bool _focused = false;
  late bool _hasText;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialDraft);
    _hasText = widget.initialDraft.trim().isNotEmpty;
    _controller.addListener(_onTextChanged);
    _focusNode.addListener(_onFocusChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = LayoutFocusScope.maybeOf(context);
    if (identical(next, _layoutFocusCoordinator)) {
      return;
    }
    _layoutFocusCoordinator?.unregister(
      LayoutFocusTargets.composerField,
      _focusNode,
    );
    _layoutFocusCoordinator = next;
    _layoutFocusCoordinator?.register(
      LayoutFocusTargets.composerField,
      _focusNode,
    );
  }

  @override
  void dispose() {
    _layoutFocusCoordinator?.unregister(
      LayoutFocusTargets.composerField,
      _focusNode,
    );
    _controller
      ..removeListener(_onTextChanged)
      ..dispose();
    _focusNode
      ..removeListener(_onFocusChanged)
      ..dispose();
    super.dispose();
  }

  void _onTextChanged() {
    widget.onDraftChanged(_controller.text);
    final next = _controller.text.trim().isNotEmpty;
    if (next == _hasText || !mounted) {
      return;
    }
    setState(() => _hasText = next);
  }

  void _onFocusChanged() {
    final next = _focusNode.hasFocus;
    if (next == _focused || !mounted) {
      return;
    }
    setState(() => _focused = next);
  }

  void _submit() {
    final text = _controller.text.trim();
    if (text.isEmpty || widget.busy || !widget.enabled) {
      return;
    }
    _controller.clear();
    widget.onSend(text);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final mobileClient = isMobileClientPlatform(context);
    final interactive = widget.enabled && !widget.busy;
    final canSend = interactive && _hasText;
    final fieldRadius = BorderRadius.circular(
      AppleControlMetrics.controlCornerRadius,
    );
    return Padding(
      padding: mobileClient
          ? const EdgeInsets.fromLTRB(12, 10, 12, 12)
          : const EdgeInsets.fromLTRB(12, 8, 12, 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.modelOptions.isNotEmpty ||
              widget.reasoningEffortOptions.isNotEmpty) ...[
            _ConversationRuntimeSettingsBar(
              enabled: interactive,
              modelOptions: widget.modelOptions,
              selectedModel: widget.selectedModel,
              reasoningEffortOptions: widget.reasoningEffortOptions,
              selectedReasoningEffort: widget.selectedReasoningEffort,
              onModelChanged: widget.onModelChanged,
              onReasoningEffortChanged: widget.onReasoningEffortChanged,
            ),
            const SizedBox(height: 8),
          ],
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: AppleGlassSurface(
                  key: const Key('agent-conversation-composer-field'),
                  borderRadius: fieldRadius,
                  focused: _focused && interactive,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    child: TextField(
                      controller: _controller,
                      focusNode: _focusNode,
                      minLines: 1,
                      maxLines: 4,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _submit(),
                      enabled: interactive,
                      cursorColor: colors.info,
                      cursorWidth: 1.2,
                      style: TextStyle(
                        color: colors.text.withAlpha(235),
                        fontSize: 14,
                        fontWeight: FontWeight.w400,
                        letterSpacing: -0.08,
                        height: 1.35,
                      ),
                      decoration: InputDecoration(
                        hintText: widget.enabled
                            ? strings.messageTarget(widget.targetLabel)
                            : widget.disabledHint,
                        hintStyle: TextStyle(
                          color: colors.textMuted.withAlpha(150),
                          fontSize: 14,
                          fontWeight: FontWeight.w400,
                          letterSpacing: -0.08,
                        ),
                        isDense: true,
                        filled: false,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        disabledBorder: InputBorder.none,
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Tooltip(
                message: strings.send,
                child: Material(
                  color: Colors.transparent,
                  shape: const CircleBorder(),
                  child: InkWell(
                    key: const Key('agent-conversation-composer-send'),
                    customBorder: const CircleBorder(),
                    onTap: canSend ? _submit : null,
                    child: AppleGlassSurface(
                      borderRadius: BorderRadius.circular(18),
                      focused: canSend,
                      fillAlpha: canSend ? 40 : 16,
                      child: SizedBox(
                        width: 36,
                        height: 36,
                        child: Center(
                          child: widget.busy
                              ? SizedBox(
                                  width: 15,
                                  height: 15,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 1.8,
                                    color: colors.info,
                                  ),
                                )
                              : Icon(
                                  Icons.arrow_upward_rounded,
                                  size: 17,
                                  color: canSend
                                      ? colors.text.withAlpha(245)
                                      : colors.textMuted.withAlpha(100),
                                ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _InactiveRuntimeMessageComposer extends StatelessWidget {
  const _InactiveRuntimeMessageComposer({required this.targetLabel});

  final String targetLabel;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: AppleGlassSurface(
              borderRadius: BorderRadius.circular(
                AppleControlMetrics.controlCornerRadius,
              ),
              fillAlpha: 14,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                child: Text(
                  strings.messageTarget(targetLabel),
                  style: TextStyle(
                    color: colors.textMuted.withAlpha(140),
                    fontSize: 14,
                    fontWeight: FontWeight.w400,
                    letterSpacing: -0.08,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _sessionRelativeUpdatedAtLabel(AgentConversationSession session) {
  final rawUpdatedAt = session.updatedAt.trim().isEmpty
      ? session.createdAt.trim()
      : session.updatedAt.trim();
  final updatedAt = DateTime.tryParse(rawUpdatedAt)?.toLocal();
  if (updatedAt == null) {
    return rawUpdatedAt;
  }
  final diff = DateTime.now().difference(updatedAt);
  if (diff.inMinutes < 1) {
    return 'now';
  }
  if (diff.inHours < 1) {
    return '${diff.inMinutes}m';
  }
  if (diff.inDays < 1) {
    return '${diff.inHours}h';
  }
  if (diff.inDays < 7) {
    return '${diff.inDays}d';
  }
  return '${updatedAt.month}/${updatedAt.day}';
}
