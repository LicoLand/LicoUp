import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/application/features/layout/layout_state_store.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/contracts/presentation/layout_state_namespace.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/layout/layout_agents_strategy.dart';
import 'package:licoup/src/frontend/layout/layout_destination_presentation.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/layout/layout_scope.dart';
import 'package:licoup/src/application/features/agents/orchestration/orchestration_target_catalog.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_pane.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_pane_controls.dart';
import 'package:licoup/src/frontend/features/agents/ui/conversation_archive_dialog.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_composer.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_composer_capsules.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_layout_metrics.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_message_display.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_session_presentation.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_display_names.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_orchestration_policy_controls.dart';
import 'package:licoup/src/frontend/features/agents/ui/composer_agent_mention.dart';
import 'package:licoup/src/frontend/features/agents/ui/ensure_main_agent_subagent_mcp.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_details_panel.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_workspace_sidebar.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_contact_list.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_conversation_header.dart';
import 'package:licoup/src/frontend/shared/platform/client_platform.dart';
import 'package:licoup/src/frontend/features/agents/ui/history_session_panel.dart';
import 'package:licoup/src/frontend/shared/ui/panel_frame.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

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
    widget.controller.activeConversationListenable.addListener(
      _handleControllerChanged,
    );
    widget.controller.liveConversationListenable.addListener(
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
    oldWidget.controller.activeConversationListenable.removeListener(
      _handleControllerChanged,
    );
    oldWidget.controller.liveConversationListenable.removeListener(
      _handleControllerChanged,
    );
    widget.controller.addListener(_handleControllerChanged);
    widget.controller.conversationStructureListenable.addListener(
      _handleControllerChanged,
    );
    widget.controller.activeConversationListenable.addListener(
      _handleControllerChanged,
    );
    widget.controller.liveConversationListenable.addListener(
      _handleControllerChanged,
    );
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleControllerChanged);
    widget.controller.conversationStructureListenable.removeListener(
      _handleControllerChanged,
    );
    widget.controller.activeConversationListenable.removeListener(
      _handleControllerChanged,
    );
    widget.controller.liveConversationListenable.removeListener(
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
  final ComposerMentionBridge _composerMentionBridge = ComposerMentionBridge();
  bool _historyCollapsed = false;
  // Default to the narrowest usable rail; users can drag wider.
  double _sidebarWidth = agentsSidebarMinWidth;
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
    _historyCollapsed = history is LayoutExpansionState
        ? !history.expanded
        : false;
    _sidebarWidth = sidebar is LayoutPaneExtentState
        ? sidebar.extent.clamp(agentsSidebarMinWidth, agentsSidebarMaxWidth)
        : agentsSidebarMinWidth;
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

  Future<void> _chooseWorkingDirectory({
    required ClientController controller,
    required String agentId,
    required String draftToken,
    required String currentDirectory,
  }) async {
    final selected = await getDirectoryPath(
      initialDirectory: currentDirectory.trim().isEmpty
          ? null
          : currentDirectory.trim(),
    );
    if (!mounted ||
        selected == null ||
        selected.trim().isEmpty ||
        controller.selectedConversationAgentId != agentId ||
        controller.newConversationDraftTokenFor(agentId) != draftToken) {
      return;
    }
    controller.selectNewConversationWorkingDirectory(selected);
  }

  Future<void> _pickConversationAttachments() async {
    const imageTypes = XTypeGroup(
      label: 'Images',
      extensions: ['png', 'jpg', 'jpeg', 'gif', 'webp'],
    );
    await openFiles(acceptedTypeGroups: [imageTypes]);
  }

  Widget _activeConversationPane({
    required ClientController controller,
    required TargetCandidate target,
    required LicoStrings strings,
    bool framed = true,
    bool showSidebarToggle = true,
  }) {
    final strategy = LayoutAgentsStrategyScope.maybeOf(context);
    final orchestrationSelected =
        controller.selectedConversationIsOrchestration;
    final managerTarget = orchestrationSelected
        ? controller.agentOrchestrationManagerTarget
        : null;
    final configuredManagerTarget = orchestrationSelected
        ? controller.agentOrchestrationConfiguredManagerTarget
        : null;
    final configuredManagerId = orchestrationSelected
        ? controller.effectiveAgentOrchestrationPolicy.plainSendDispatchAgentId
        : '';
    final showWorkingDirectory =
        !controller.mobileClientRuntimePlatform &&
        !(orchestrationSelected
            ? (configuredManagerTarget ?? managerTarget)
                      ?.hasValidVirtualMachineConnection ==
                  true
            : target.hasValidVirtualMachineConnection);
    final workingDirectorySelectable =
        showWorkingDirectory &&
        controller.canSelectNewConversationWorkingDirectory;
    final composerEnabled = orchestrationSelected
        ? managerTarget != null
        : target.canRelayRuntime;
    final gateReasonCode = orchestrationSelected
        ? (composerEnabled
              ? controller.conversationSendErrorFor(managerTarget!.target)
              : !controller.agentOrchestrationPolicyConfigured
              ? 'orchestration_policy_required'
              : 'orchestration_targets_unavailable')
        : (composerEnabled
              ? controller.conversationSendErrorFor(target.target)
              : target.conversationSendGateReason);
    final session = controller.selectedConversationSession;
    final opencodeServeState = controller.opencodeServeState;
    final opencodeServeStatus =
        switch ((opencodeServeState?['status'] as String?)?.trim()) {
          'running' => AgentConversationServeStatus.running,
          'blocked' => AgentConversationServeStatus.blocked,
          'unavailable' => AgentConversationServeStatus.unavailable,
          _ => AgentConversationServeStatus.stopped,
        };
    final flywheelPolicy = orchestrationSelected
        ? controller.effectiveAgentOrchestrationPolicy
        : null;
    // Capsule chrome defaults to the first Daily Conversation agent (Adaptive
    // Flywheel priority list). Current Conversation (`main_agent`) still owns
    // send dispatch when it differs.
    final primaryDaily = flywheelPolicy?.primaryDailyConversationAgent;
    final flywheelAgentId =
        (primaryDaily?.agentId.trim().isNotEmpty ?? false)
        ? primaryDaily!.agentId.trim()
        : configuredManagerId.trim();
    TargetCandidate? flywheelDisplayTarget;
    if (flywheelAgentId.isNotEmpty) {
      for (final candidate in controller.scannedTargets) {
        if (candidate.target == flywheelAgentId) {
          flywheelDisplayTarget = candidate;
          break;
        }
      }
    }
    final flywheelAgentLabel = flywheelDisplayTarget != null
        ? agentConversationTargetDisplayName(flywheelDisplayTarget)
        : flywheelAgentId.isNotEmpty
        ? flywheelAgentId
        : strings.notConfigured;
    final flywheelModel = primaryDaily != null
        ? primaryDaily.modelName.trim()
        : (flywheelPolicy?.commanderModelName.trim() ?? '');
    final flywheelEffort = primaryDaily != null
        ? primaryDaily.reasoningEffort.trim()
        : (flywheelPolicy?.commanderReasoningEffort.trim() ?? '');
    final flywheelFast = primaryDaily?.fast ?? false;
    final flywheelLabel = orchestrationSelected
        ? composeOrchestrationAssignmentCapsuleLabel(
            agentLabel: flywheelAgentLabel,
            modelName: flywheelModel,
            reasoningEffort: flywheelEffort,
            fast: flywheelFast,
            fastLabel: strings.fastModeLabel,
            effortLabel: (effort) =>
                strings.reasoningEffortOptionLabel(effort, effort),
            modelDisplayName: flywheelDisplayTarget == null
                ? null
                : (model) => agentOrchestrationModelDisplayName(
                    flywheelDisplayTarget!,
                    model,
                  ),
          )
        : flywheelAgentLabel;
    final participantTargets = orchestrationSelected
        ? controller.groupConversationParticipantTargets
        : controller.scannedTargets;
    final primaryConversationId = session == null
        ? ''
        : messagingDetailsConversationId(session);
    final participantConversationIds = <String, String>{};
    if (orchestrationSelected) {
      for (final entry in controller.groupConversationAgentSessions.entries) {
        final nativeId = entry.value.nativeSessionId.trim();
        if (nativeId.isNotEmpty) {
          participantConversationIds[entry.key] = nativeId;
        }
      }
      final mainId = controller
          .effectiveAgentOrchestrationPolicy
          .plainSendDispatchAgentId;
      if (mainId.isNotEmpty && primaryConversationId.isNotEmpty) {
        participantConversationIds.putIfAbsent(
          mainId,
          () => primaryConversationId,
        );
      }
    } else {
      final agentId = target.target.trim();
      if (agentId.isNotEmpty && primaryConversationId.isNotEmpty) {
        participantConversationIds[agentId] = primaryConversationId;
      }
    }
    final state = AgentConversationPaneState(
      target: target,
      session: session,
      liveMessages: controller.selectedLiveConversationMessages,
      recentSessions: controller.selectedConversationSessions
          .take(3)
          .toList(growable: false),
      loading: controller.isLoadingConversations,
      turnActive: controller.isSendingConversationMessage,
      preparingNewConversation: controller.preparingNewConversation,
      orchestrationSelected: orchestrationSelected,
      composerEnabled: composerEnabled,
      sendGateReasonCode: gateReasonCode,
      composerDraft: controller.conversationComposerDraft,
      // Group entry: model selection lives in Adaptive Flywheel edit, not a
      // top-level Model capsule. The flywheel hover panel inserts @mentions.
      modelOptions: orchestrationSelected
          ? const []
          : controller.selectedConversationModelOptions,
      selectedModel: orchestrationSelected
          ? ''
          : controller.selectedConversationModel,
      defaultModel: orchestrationSelected
          ? ''
          : controller.selectedConversationDefaultModel,
      reasoningEffortOptions: orchestrationSelected
          ? const []
          : controller.selectedConversationReasoningEffortOptions,
      selectedReasoningEffort: orchestrationSelected
          ? ''
          : controller.selectedConversationReasoningEffort,
      defaultReasoningEffort: orchestrationSelected
          ? ''
          : controller.selectedConversationDefaultReasoningEffort,
      showWorkingDirectory: showWorkingDirectory,
      workingDirectory: showWorkingDirectory
          ? controller.selectedConversationWorkingDirectory
          : '',
      workingDirectorySelectable: workingDirectorySelectable,
      sendAuthorizeActive: controller.isAuthorizingConversationRuntime,
      permissionRetryTool: controller.pendingPermissionRetryTool,
      participantTargets: participantTargets,
      flywheelMainAgentLabel: orchestrationSelected ? flywheelLabel : '',
      flywheelMainAgentTarget: orchestrationSelected
          ? flywheelDisplayTarget
          : null,
      flywheelMentionSections: orchestrationSelected && flywheelPolicy != null
          ? buildComposerFlywheelMentionSections(
              policy: flywheelPolicy,
              scannedTargets: controller.scannedTargets,
              strings: strings,
            )
          : const [],
      showLicoProfileCapsule:
          controller.selectedConversationSupportsLicoProfile,
      selectedLicoProfile: controller.selectedConversationLicoProfile,
      planDocumentPath: _planDocumentPath(controller),
      groupRosterParticipants: orchestrationSelected
          ? controller.groupConversationRosterParticipants
          : const [],
      participantConversationIds: participantConversationIds,
    );
    final onUnblockSend = switch (gateReasonCode) {
      'orchestration_policy_required' => () => unawaited(
        showAgentOrchestrationPolicyEditor(context, controller),
      ),
      'native_agent_executable_not_detected' ||
      'native_agent_runtime_profile_unavailable' ||
      'runtime_message_send_unavailable' => () => unawaited(
        controller.scanTargets(),
      ),
      'antigravity_auth_required' => () => unawaited(
        controller.authorizeSelectedConversationRuntime(),
      ),
      _ => null,
    };
    final actions = AgentConversationPaneActions(
      onModelChanged: controller.selectConversationModel,
      onReasoningEffortChanged: controller.selectConversationReasoningEffort,
      onDraftChanged: controller.updateConversationComposerDraft,
      onPermissionRetry: () => controller.retryDeniedConversationTurn(),
      onPermissionRetryRemember: () =>
          controller.retryDeniedConversationTurn(remember: true),
      onPermissionDeny: controller.dismissDeniedConversationTurn,
      onSend: (text) async {
        if (controller.selectedConversationIsOrchestration) {
          final mentionCatalog = [
            for (final participant
                in controller.groupConversationRosterParticipants)
              if ((participant.agentId?.trim().isNotEmpty ?? false))
                (
                  id: participant.agentId!.trim(),
                  label: participant.displayName.trim().isNotEmpty
                      ? participant.displayName.trim()
                      : participant.agentId!.trim(),
                ),
          ];
          final mentioned = parseComposerAgentMentionIds(
            text: text,
            agents: mentionCatalog,
          );
          // Plain send (no @) must match the flywheel capsule: first Daily
          // Conversation agent. @mentions route to the named peer and do not
          // require Subagent MCP on that peer to receive the user turn.
          if (mentioned.isEmpty) {
            final ensureId = controller
                .effectiveAgentOrchestrationPolicy
                .plainSendDispatchAgentId;
            if (ensureId.isNotEmpty) {
              final ready = await ensureMainAgentSubagentMcp(
                context: context,
                controller: controller,
                agentId: ensureId,
              );
              if (!ready) return false;
            }
          }
        }
        return controller.sendConversationMessage(text);
      },
      onSelectSession: controller.selectConversationSession,
      onUnblockSend: onUnblockSend,
      onChooseWorkingDirectory: workingDirectorySelectable
          ? () => unawaited(
              _chooseWorkingDirectory(
                controller: controller,
                agentId: target.target,
                draftToken: controller.selectedNewConversationDraftToken,
                currentDirectory:
                    controller.selectedConversationWorkingDirectory,
              ),
            )
          : null,
      onAttach:
          strategy.messageStyle == AgentsMessageStyle.participantFlow &&
              !controller.mobileClientRuntimePlatform
          ? () => unawaited(_pickConversationAttachments())
          : null,
      onEditFlywheel: orchestrationSelected
          ? () => unawaited(
              showAgentOrchestrationPolicyEditor(context, controller),
            )
          : null,
      onMentionFlywheelAgent: orchestrationSelected
          ? (entry) => _composerMentionBridge.insertMention(
              agentId: entry.agentId,
              displayLabel: entry.displayLabel,
              target: entry.target,
            )
          : null,
      mentionBridge: orchestrationSelected ? _composerMentionBridge : null,
      onLicoProfileChanged: controller.selectedConversationSupportsLicoProfile
          ? controller.selectConversationLicoProfile
          : null,
    );
    final headerState = AgentConversationHeaderState(
      target: target,
      session: session,
      historyCollapsed: _historyCollapsed,
      collapseHistoryTooltip: strings.collapseHistoryConversations,
      expandHistoryTooltip: strings.expandHistoryConversations,
      orchestrationSelected: orchestrationSelected,
      opencodeServeState: opencodeServeState == null
          ? null
          : AgentConversationServeState(
              status: opencodeServeStatus,
              port: opencodeServeState['port'] is int
                  ? opencodeServeState['port'] as int
                  : null,
              portConflict: opencodeServeState['portConflict'] == true,
            ),
      showSidebarToggle: showSidebarToggle,
    );
    // Messaging moves flywheel controls into the composer capsule row; console
    // keeps the compact header pill.
    final messaging =
        strategy.messageStyle == AgentsMessageStyle.participantFlow;
    final policyControls = orchestrationSelected && !messaging
        ? AgentOrchestrationPolicyHeaderControls(
            mainAgentLabel: flywheelLabel,
            mainAgentTarget: flywheelDisplayTarget,
            onEdit: () => unawaited(
              showAgentOrchestrationPolicyEditor(context, controller),
            ),
          )
        : null;
    final pane = AgentConversationActivePane(
      state: state,
      actions: actions,
      header: messaging
          ? MessagingConversationHeader(
              target: target,
              session: session,
              detailsState: state,
              detailsActions: actions,
              opencodeServeState: headerState.opencodeServeState,
              switcherSessions: controller.selectedConversationSessions,
              switcherSelectedSessionId:
                  controller.selectedConversationSession?.id ?? '',
              onSwitchConversation: controller.selectConversationSession,
              onSwitchNewConversation: controller.startNewConversationSession,
              switcherRunningFor: (candidate) {
                final nativeId = candidate.nativeSessionId.trim();
                final selectedSessionId =
                    controller.selectedConversationSession?.id ?? '';
                return controller.isSendingConversationMessage &&
                    ((controller.sendingConversationSessionId.isNotEmpty &&
                            candidate.id ==
                                controller.sendingConversationSessionId) ||
                        (controller
                                .sendingConversationNativeSessionId
                                .isNotEmpty &&
                            nativeId ==
                                controller
                                    .sendingConversationNativeSessionId) ||
                        (controller.sendingConversationSessionId.isEmpty &&
                            controller
                                .sendingConversationNativeSessionId
                                .isEmpty &&
                            candidate.id == selectedSessionId));
              },
            )
          : ConversationPaneHeader(
              state: headerState,
              actions: AgentConversationHeaderActions(
                onToggleHistory: _toggleHistoryCollapsed,
              ),
              orchestrationControls: policyControls,
              strategy: strategy,
            ),
      framed: framed,
    );
    return pane;
  }

  Widget _detailForSelection({
    required TargetCandidate? target,
    required Widget conversationPane,
  }) {
    return target == null
        ? AgentConversationEmptySelection(
            allowManualTargetActions: widget.allowManualTargetActions,
            onAddTarget: widget.onAddTarget,
          )
        : conversationPane;
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
          final strategy = LayoutAgentsStrategyScope.maybeOf(context);
          final agentTreeSidebar = AgentsWorkspaceSidebar(
            targets: widget.targets,
            sessionsByAgent: controller.conversationSessionsByAgent,
            selectedSessionId: controller.selectedConversationSession?.id ?? '',
            activityFor: controller.conversationTabActivityFor,
            onSelectSession: (agentId, sessionId) async {
              await controller.selectConversationAgent(agentId);
              controller.selectConversationSession(sessionId);
            },
            onNewConversation: controller.startNewConversationSession,
            onPrefetchSessions: (agentId) =>
                unawaited(controller.refreshConversationSessions(agentId)),
            onArchive: () => unawaited(
              showConversationArchiveDialog(
                context,
                controller,
                sourceAgentId: '',
              ),
            ),
            onAddTarget: onAddTarget,
            onRefresh: () {
              for (final target in widget.targets) {
                if (target.isConversationAgent) {
                  unawaited(controller.refreshConversationSessions(target.id));
                }
              }
            },
            refreshing: controller.isLoadingConversations,
            allowManualTargetActions: allowManualTargetActions,
            scanning: widget.scanning,
            adding: widget.adding,
          );
          final sidebar = switch (strategy.sidebarStyle) {
            AgentsSidebarStyle.agentTree => agentTreeSidebar,
            AgentsSidebarStyle.flatRecencyList => MessagingContactList(
              targets: widget.targets,
              sessionsByAgent: controller.conversationSessionsByAgent,
              selectedAgentId: controller.selectedConversationAgentId,
              activityFor: controller.conversationTabActivityFor,
              onSelectAgent: (agentId) => unawaited(() async {
                if (agentId == controller.selectedConversationAgentId) {
                  // Tapping the active contact returns to its
                  // new-conversation home.
                  controller.startNewConversationSession();
                  return;
                }
                await controller.selectConversationAgent(agentId);
              }()),
              onNewConversation: controller.startNewConversationSession,
              onPrefetchSessions: (agentId) =>
                  unawaited(controller.refreshConversationSessions(agentId)),
              isPinned: controller.isConversationTargetPinned,
              onTogglePinned: (agentId) =>
                  unawaited(controller.toggleConversationTargetPinned(agentId)),
              scanning: widget.scanning,
              loading: controller.isLoadingConversations,
            ),
          };
          final detail = _detailForSelection(
            target: target,
            conversationPane: conversationPane,
          );
          final sidebarPane = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [Expanded(child: sidebar)],
          );
          return presentation.frameWorkspace(
            context,
            key: const Key('agents-workspace-layout'),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!_historyCollapsed)
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
                      key: const Key('agents-workspace-detail-pane'),
                      sidebarCollapsed: _historyCollapsed,
                      child: detail,
                    ),
                  ),
                ),
              ],
            ),
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
          : _activeConversationPane(
              controller: controller,
              target: target,
              strings: strings,
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
      return _activeConversationPane(
        controller: controller,
        target: target,
        strings: strings,
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 760;
        final chatPane = _activeConversationPane(
          controller: controller,
          target: target,
          strings: strings,
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
        final embeddedChatPane = _activeConversationPane(
          controller: controller,
          target: target,
          strings: strings,
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

String _planDocumentPath(ClientController controller) {
  if (!controller.selectedConversationSupportsLicoProfile ||
      controller.selectedConversationLicoProfile != 'plan') {
    return '';
  }
  final root = controller.portableDataPath.trim();
  if (root.isEmpty) return '';
  return p.join(root, 'client-state', 'plans', 'active-plan.md');
}
