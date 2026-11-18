import 'dart:async';

import 'package:licoup/src/frontend/features/agents/ui/native_approval_card.dart';
import 'package:licoup/src/frontend/features/agents/ui/conversation_execution_binding_viewer.dart';
import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'package:licoup/src/contracts/agent_conversation_attachment.dart';
import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/agent_conversation_tab_activity.dart';
import 'package:licoup/src/contracts/client_conversation_models.dart';
import 'package:licoup/src/contracts/presentation/layout_state_namespace.dart';
import 'package:licoup/src/frontend/layout/layout_state_port.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/binding/projection_builder.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_layout_metrics.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_pane.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_message_blocks/native_subagent_history_scope.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_workspace_sidebar.dart';
import 'package:licoup/src/frontend/features/agents/ui/conversation_archive_dialog.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_contact_list.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_conversation_header.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_conversation_history_menu.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_conversation_overlay_glass.dart';
import 'package:licoup/src/frontend/features/agents/ui/conversation/canonical_group_conversation_pane.dart';
import 'package:licoup/src/frontend/features/agents/ui/conversation/conversation_profile_create_dialog.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_agents_directive.dart';
import 'package:licoup/src/frontend/layout/layout_agents_strategy.dart';
import 'package:licoup/src/frontend/layout/layout_destination_presentation.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/layout/layout_scope.dart';
import 'package:licoup/src/frontend/shared/messaging/messaging_sidebar_column.dart';
import 'package:licoup/src/frontend/shared/platform/client_platform.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';
import 'package:licoup/src/frontend/shared/ui/lico_window_ground.dart';
import 'package:licoup/src/frontend/shared/ui/messaging_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/agents/agents_binding.dart';
import 'package:licoup/src/presentation/agents/agents_intent.dart';
import 'package:licoup/src/presentation/agents/agents_projection.dart';
import 'package:licoup/src/presentation/conversation/conversation_binding.dart';
import 'package:licoup/src/presentation/conversation/conversation_effect.dart';
import 'package:licoup/src/presentation/conversation/conversation_intent.dart';
import 'package:licoup/src/presentation/conversation/conversation_projection.dart';

import 'package:licoup/src/presentation/presentation_semantics.dart';

const _conversationAttachmentMediaUnsupported = 'attachment_media_unsupported';

class AgentConversationWorkspace extends StatefulWidget {
  const AgentConversationWorkspace({
    super.key,
    required this.agents,
    required this.conversation,
    required this.onAddTarget,
    this.onSelectDestination,
    this.onSearch,
    this.allowManualTargetActions = true,
  });

  final AgentsBinding agents;
  final ConversationBinding conversation;
  final VoidCallback onAddTarget;
  final ValueChanged<ClientSection>? onSelectDestination;
  final VoidCallback? onSearch;
  final bool allowManualTargetActions;

  @override
  State<AgentConversationWorkspace> createState() =>
      _AgentConversationWorkspaceState();
}

class _AgentConversationWorkspaceState
    extends State<AgentConversationWorkspace> {
  bool _sidebarCollapsed = false;
  double _sidebarWidth = agentsSidebarMinWidth;
  LayoutScopedState? _layoutState;
  String? _layoutStateIdentity;
  StreamSubscription<ConversationEffect>? _conversationEffects;
  bool _pickingConversationAttachments = false;
  bool _showAgentDetailInsideGroupList = false;
  String? _observedConversationSelection;
  String _warmedBrowseCatalogSignature = '';
  bool _localGroupAutoSelected = false;

  @override
  void initState() {
    super.initState();
    _listenForConversationEffects();
  }

  @override
  void didUpdateWidget(covariant AgentConversationWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(
      oldWidget.conversation.effects,
      widget.conversation.effects,
    )) {
      unawaited(_conversationEffects?.cancel());
      _listenForConversationEffects();
    }
  }

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
    if (_layoutStateIdentity == identity) return;
    _layoutStateIdentity = identity;
    _layoutState = scope.state;

    final history = scope.state.readIfDeclared(
      LayoutStateChannels.agentsHistory,
    );
    final sidebar = scope.state.readIfDeclared(
      LayoutStateChannels.agentsSidebar,
    );
    _sidebarCollapsed = history is LayoutExpansionState
        ? !history.expanded
        : false;
    _sidebarWidth = sidebar is LayoutPaneExtentState
        ? sidebar.extent.clamp(agentsSidebarMinWidth, agentsSidebarMaxWidth)
        : agentsSidebarMinWidth;
  }

  @override
  void dispose() {
    unawaited(_conversationEffects?.cancel());
    super.dispose();
  }

  void _listenForConversationEffects() {
    _conversationEffects = widget.conversation.effects.effects.listen((effect) {
      if (effect case ConversationAttachmentSelectionRequested(
        :final conversationId,
      )) {
        unawaited(_pickConversationAttachments(conversationId));
      }
    });
  }

  /// Tracks the durable selection so user navigation can dismiss the empty
  /// state and leave the member-session view. Selecting another in-group
  /// session keeps the canonical group's `group:` identity, so the member
  /// view survives member-session picks but not group/agent navigation.
  void _syncConversationSelection(
    AgentsProjection agents,
    ConversationProjection root,
    NativeConversationCatalogProjection native,
    CanonicalConversationProjection canonical,
  ) {
    final groupId =
        root.authority == ConversationAuthority.canonicalConversation
        ? canonical.conversationId.trim()
        : '';
    final agentId = agents.selectedAgentId.trim();
    final sessionId = _selectedSession(native)?.id.trim() ?? '';
    final selection = groupId.isNotEmpty
        ? 'group:$groupId'
        : agentId.isNotEmpty
        ? 'agent:$agentId:$sessionId'
        : '';
    if (_observedConversationSelection == selection) return;
    _observedConversationSelection = selection;
    _showAgentDetailInsideGroupList = false;
  }

  /// Layout-directed default: shells that always show a conversation (the
  /// Desktop split workspace) ask the workspace to open the pinned Local
  /// group once whenever it settles with nothing selected. A restored or
  /// user-driven selection always wins; the request fires at most once per
  /// mount so an explicit deselect is never overridden.
  void _selectLocalGroupWhenIdle(
    ConversationProjection root,
    CanonicalConversationProjection canonical,
    AgentsProjection agents,
  ) {
    if (_localGroupAutoSelected) return;
    final hasSelection =
        root.authority == ConversationAuthority.canonicalConversation
        ? canonical.conversationId.trim().isNotEmpty
        : agents.selectedAgentId.trim().isNotEmpty;
    if (hasSelection) {
      _localGroupAutoSelected = true;
      return;
    }
    String? localGroupId;
    for (final group in canonical.groupConversations) {
      if (group.id == ClientConversation.defaultLocalAgentGroupId) {
        localGroupId = group.id;
        break;
      }
    }
    final selectedId = localGroupId;
    if (selectedId == null) return;
    _localGroupAutoSelected = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.conversation.intents.send(SelectCanonicalConversation(selectedId));
    });
  }

  /// The member's in-group history menu, anchored at the tapped roster or
  /// members-panel row. Choosing a session selects it through the canonical
  /// group's session path and opens the member-session view, which the
  /// header's "Back to group" exits.
  void _openMemberConversationHistory(
    TargetCandidate target,
    Offset globalPosition,
  ) {
    final native = widget.conversation.nativeCatalog.current;
    final groupId = widget.conversation.canonicalEvents.current.conversationId
        .trim();
    if (groupId.isEmpty) return;
    final sessionsByAgent = native.groupSessionsByAgent;
    final sessions =
        sessionsByAgent[target.target] ??
        sessionsByAgent[target.id] ??
        const <AgentConversationSession>[];
    final memberId =
        sessionsByAgent.containsKey(target.id) &&
            !sessionsByAgent.containsKey(target.target)
        ? target.id
        : target.target;
    final selectedAgentId = widget.agents.projection.current.selectedAgentId
        .trim();
    final showsMember =
        selectedAgentId == memberId || selectedAgentId == target.id;
    unawaited(
      showMessagingConversationHistoryMenu(
        context: context,
        globalPosition: globalPosition,
        sessions: sessions,
        selectedSessionId: showsMember
            ? (_selectedSession(native)?.id ?? '')
            : '',
        runningFor: (candidate) =>
            native.runningSessionIds.contains(candidate.id),
        onSelect: (sessionId) {
          widget.agents.intents.send(
            SelectGroupAgentConversationSession(
              groupConversationId: groupId,
              agentId: memberId,
              sessionId: sessionId,
            ),
          );
          if (!_showAgentDetailInsideGroupList) {
            setState(() => _showAgentDetailInsideGroupList = true);
          }
        },
      ),
    );
  }

  void _scheduleAgentBrowseCatalogWarm(AgentsProjection agents) {
    final ids = [
      for (final target in agents.targetDetails)
        if (target.isConversationAgent) target.target.trim(),
    ]..sort();
    final signature = ids.join(',');
    if (signature.isEmpty || signature == _warmedBrowseCatalogSignature) {
      return;
    }
    _warmedBrowseCatalogSignature = signature;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      for (final agentId in ids) {
        widget.conversation.intents.send(
          RefreshConversationCatalog(agentId: agentId),
        );
      }
    });
  }

  void _writeLayoutState(
    LayoutStateChannel channel,
    LayoutPresentationStateValue value,
  ) {
    _layoutState?.writeIfDeclared(channel, value);
  }

  void _toggleSidebarCollapsed() {
    setState(() => _sidebarCollapsed = !_sidebarCollapsed);
    _writeLayoutState(
      LayoutStateChannels.agentsHistory,
      LayoutExpansionState(!_sidebarCollapsed),
    );
  }

  Future<void> _pickConversationAttachments(String conversationId) async {
    if (conversationId.trim().isEmpty || _pickingConversationAttachments) {
      return;
    }
    _pickingConversationAttachments = true;
    try {
      const images = XTypeGroup(
        label: 'Images',
        extensions: <String>['png', 'jpg', 'jpeg', 'gif', 'webp'],
      );
      final files = await openFiles(acceptedTypeGroups: const [images]);
      if (!mounted) return;
      if (files.isEmpty) {
        widget.conversation.intents.send(
          SetConversationAttachmentStatus(
            conversationId,
            conversationAttachmentStatusCancelled,
          ),
        );
        return;
      }
      final selectionId = DateTime.now().microsecondsSinceEpoch;
      final attachments = <ConversationAttachment>[];
      for (var index = 0; index < files.length; index += 1) {
        final file = files[index];
        final extension = p.extension(file.name).replaceFirst('.', '');
        final mediaType = conversationAttachmentMediaTypeForExtension(
          extension,
        );
        if (mediaType.isEmpty) {
          widget.conversation.intents.send(
            SetConversationAttachmentStatus(
              conversationId,
              _conversationAttachmentMediaUnsupported,
            ),
          );
          return;
        }
        attachments.add(
          ConversationAttachment(
            id: 'attachment-$selectionId-$index',
            name: file.name,
            mediaType: mediaType,
            path: file.path,
          ),
        );
      }
      widget.conversation.intents.send(
        StageConversationAttachments(conversationId, attachments),
      );
    } on Object {
      if (!mounted) return;
      widget.conversation.intents.send(
        SetConversationAttachmentStatus(
          conversationId,
          conversationAttachmentStatusFailed,
        ),
      );
    } finally {
      _pickingConversationAttachments = false;
    }
  }

  Future<void> _chooseWorkingDirectory(String currentDirectory) async {
    final selected = await getDirectoryPath(
      initialDirectory: currentDirectory.trim().isEmpty
          ? null
          : currentDirectory,
    );
    if (!mounted || selected == null || selected.trim().isEmpty) return;
    widget.agents.intents.send(SelectAgentWorkingDirectory(selected));
  }

  @override
  Widget build(BuildContext context) {
    return ProjectionBuilder<AgentsProjection, AgentsProjection>(
      source: widget.agents.projection,
      select: (projection) => projection,
      builder: (context, agents) =>
          ProjectionBuilder<ConversationProjection, ConversationProjection>(
            source: widget.conversation.projection,
            select: (projection) => projection,
            builder: (context, root) =>
                ProjectionBuilder<
                  NativeConversationCatalogProjection,
                  NativeConversationCatalogProjection
                >(
                  source: widget.conversation.nativeCatalog,
                  select: (projection) => projection,
                  builder: (context, native) =>
                      ProjectionBuilder<
                        CanonicalConversationProjection,
                        CanonicalConversationProjection
                      >(
                        source: widget.conversation.canonicalEvents,
                        select: (projection) => projection,
                        builder: (context, canonical) =>
                            ProjectionBuilder<
                              PersistentTurnProjection,
                              PersistentTurnProjection
                            >(
                              source: widget.conversation.persistentTurns,
                              select: (projection) => projection,
                              builder: (context, turns) =>
                                  ProjectionBuilder<
                                    ComposerProjection,
                                    ComposerProjection
                                  >(
                                    source: widget.conversation.composer,
                                    select: (projection) => projection,
                                    builder: (context, composer) =>
                                        ProjectionBuilder<
                                          ConversationAttachmentsProjection,
                                          ConversationAttachmentsProjection
                                        >(
                                          source:
                                              widget.conversation.attachments,
                                          select: (projection) => projection,
                                          builder: (context, attachments) =>
                                              ProjectionBuilder<
                                                ConversationTabActivityProjection,
                                                ConversationTabActivityProjection
                                              >(
                                                source: widget
                                                    .conversation
                                                    .tabActivity,
                                                select: (projection) =>
                                                    projection,
                                                builder: (context, tabActivity) =>
                                                    ProjectionBuilder<
                                                      ConversationArchiveProjection,
                                                      ConversationArchiveProjection
                                                    >(
                                                      source: widget
                                                          .conversation
                                                          .archive,
                                                      select: (projection) =>
                                                          projection,
                                                      builder:
                                                          (context, archive) =>
                                                              _buildWorkspace(
                                                                context,
                                                                agents,
                                                                root,
                                                                native,
                                                                canonical,
                                                                turns,
                                                                composer,
                                                                attachments,
                                                                tabActivity,
                                                                archive,
                                                              ),
                                                    ),
                                              ),
                                        ),
                                  ),
                            ),
                      ),
                ),
          ),
    );
  }

  Widget _buildWorkspace(
    BuildContext context,
    AgentsProjection agents,
    ConversationProjection root,
    NativeConversationCatalogProjection native,
    CanonicalConversationProjection canonical,
    PersistentTurnProjection turns,
    ComposerProjection composer,
    ConversationAttachmentsProjection attachments,
    ConversationTabActivityProjection tabActivity,
    ConversationArchiveProjection archive,
  ) {
    _syncConversationSelection(agents, root, native, canonical);
    _scheduleAgentBrowseCatalogWarm(agents);
    final directive = LayoutAgentsDirectiveScope.maybeOf(context);
    if (directive != null && directive.selectLocalGroupWhenIdle) {
      _selectLocalGroupWhenIdle(root, canonical, agents);
    }
    final sidebarCollapsed = directive?.sidebarCollapsed ?? _sidebarCollapsed;
    final presentation = layoutAgentsPresentationOf(context);
    final selectedTarget = _selectedTarget(agents);
    final selectedSession = _selectedSession(native);
    final mobile = agents.mobileRuntime || isMobileClientPlatform(context);
    final canonicalDetail =
        root.authority == ConversationAuthority.canonicalConversation &&
        !_showAgentDetailInsideGroupList;
    final pane = canonicalDetail
        ? CanonicalGroupConversationPane(
            conversation: widget.conversation,
            agents: widget.agents,
            canonical: canonical,
            turns: turns,
            composer: composer,
            attachments: attachments,
            framed: mobile,
            onOpenMemberHistory: _openMemberConversationHistory,
            onOpenSettings: widget.onSelectDestination == null
                ? null
                : () => widget.onSelectDestination!(ClientSection.settings),
          )
        : selectedTarget == null
        ? _EmptyConversation(
            onAddTarget: widget.allowManualTargetActions
                ? widget.onAddTarget
                : null,
          )
        : _nativeConversationPane(
            context,
            selectedTarget,
            selectedSession,
            native,
            turns,
            composer,
            attachments,
            mobile: mobile,
            onBackToGroup: _showAgentDetailInsideGroupList
                ? () {
                    final groupId = canonical.conversationId.trim();
                    setState(() => _showAgentDetailInsideGroupList = false);
                    if (groupId.isNotEmpty) {
                      widget.conversation.intents.send(
                        SelectCanonicalConversation(groupId),
                      );
                    }
                  }
                : null,
          );
    final detail = tabActivity.pendingApprovals.isEmpty
        ? pane
        : Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
                child: NativeApprovalCard(
                  approvals: tabActivity.pendingApprovals,
                  errorCode: tabActivity.approvalErrorCode,
                  intents: widget.conversation.intents,
                ),
              ),
              Expanded(child: pane),
            ],
          );
    if (mobile) {
      return LicoWindowGround(
        key: const Key('agents-workspace-shell'),
        color: presentation.canvasColor(context.layoutPalette),
        child: detail,
      );
    }

    if (directive != null &&
        directive.sidebarMode != LayoutAgentsSidebarMode.list) {
      return _avatarWorkspace(
        context,
        directive,
        agents,
        native,
        canonical,
        tabActivity,
        archive,
        detail,
      );
    }

    final sidebar = _sidebar(agents, native, canonical, tabActivity, archive);
    final layout = LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = math
            .max(
              agentsSidebarMinWidth,
              constraints.maxWidth -
                  agentsSidebarDividerWidth -
                  agentsFloatingMinChatWidth -
                  presentation.sidebarOuterHorizontalExtent -
                  presentation.detailOuterHorizontalExtent,
            )
            .clamp(agentsSidebarMinWidth, agentsSidebarMaxWidth)
            .toDouble();
        final width = _sidebarWidth
            .clamp(agentsSidebarMinWidth, maxWidth)
            .toDouble();
        final framedDetail = presentation.frameDetail(
          context,
          key: const Key('agents-workspace-detail-pane'),
          sidebarCollapsed: sidebarCollapsed,
          child: detail,
        );
        final hosted = MessagingSidebarGeometryScope.maybeOf(context) != null;
        return presentation.frameWorkspace(
          context,
          key: const Key('agents-workspace-layout'),
          child: hosted
              ? MessagingSidebarColumn(
                  sidebar: sidebar,
                  detail: framedDetail,
                  sidebarCollapsed: sidebarCollapsed,
                )
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (!sidebarCollapsed)
                      presentation.frameSidebar(
                        context,
                        key: const Key('agents-workspace-sidebar-card'),
                        child: SizedBox(width: width, child: sidebar),
                      ),
                    Expanded(
                      child: PaneEdgeDragHandle(
                        dragHandleKey: const Key(
                          'agents-workspace-split-divider',
                        ),
                        width: agentsSidebarDividerWidth,
                        enabled: !sidebarCollapsed,
                        onDragDelta: (delta) {
                          setState(() {
                            _sidebarWidth = (width + delta)
                                .clamp(agentsSidebarMinWidth, maxWidth)
                                .toDouble();
                          });
                          _writeLayoutState(
                            LayoutStateChannels.agentsSidebar,
                            LayoutPaneExtentState(_sidebarWidth),
                          );
                        },
                        child: framedDetail,
                      ),
                    ),
                  ],
                ),
        );
      },
    );

    // Flat shells leave the window backdrop visible under the list column:
    // the detail frames its own ground so the ambient layer stays inside
    // the detail bounds.
    return presentation.canvasGroundsWorkspace
        ? LicoWindowGround(
            key: const Key('agents-workspace-shell'),
            color: presentation.canvasColor(context.layoutPalette),
            child: layout,
          )
        : layout;
  }

  /// The hosted-sidebar arrangement: a pinned avatar column beside the
  /// detail, the header switcher's full list over the detail, or the avatar
  /// column alone while the shell shows its rail.
  Widget _avatarWorkspace(
    BuildContext context,
    LayoutAgentsDirective directive,
    AgentsProjection agents,
    NativeConversationCatalogProjection native,
    CanonicalConversationProjection canonical,
    ConversationTabActivityProjection tabActivity,
    ConversationArchiveProjection archive,
    Widget detail,
  ) {
    final rail = directive.sidebarMode == LayoutAgentsSidebarMode.avatarRail;
    final expand = directive.onExpandSidebar;
    final toggleSwitcher = directive.onToggleSwitcher;
    final switcherOpen =
        !rail && directive.switcherOpen && toggleSwitcher != null;
    final column = Container(
      key: const Key('agents-workspace-avatar-column'),
      width: MessagingDesktopMetrics.avatarColumnExtent,
      decoration: BoxDecoration(
        border: Border(
          right: BorderSide(
            color: context.licoColors.isDark
                ? const Color(0x0FFFFFFF)
                : Colors.black.withValues(alpha: 0.07),
            width: 0.5,
          ),
        ),
      ),
      child: _sidebar(
        agents,
        native,
        canonical,
        tabActivity,
        archive,
        avatarColumn: true,
        avatarColumnLeading: rail && expand != null
            ? _AvatarRailExpandControl(onTap: expand)
            : null,
        afterSelect: rail
            ? expand
            : switcherOpen
            ? toggleSwitcher
            : null,
      ),
    );
    if (rail) {
      return KeyedSubtree(
        key: const Key('agents-workspace-avatar-rail'),
        child: column,
      );
    }
    final colors = context.licoColors;
    final presentation = layoutAgentsPresentationOf(context);
    return LicoWindowGround(
      key: const Key('agents-workspace-shell'),
      color: presentation.canvasColor(context.layoutPalette),
      child: Row(
        key: const Key('agents-workspace-avatar-layout'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          column,
          ColoredBox(
            color: colors.line.withAlpha(colors.isDark ? 70 : 110),
            child: const SizedBox(width: 0.5),
          ),
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                detail,
                if (switcherOpen) ...[
                  Positioned.fill(
                    child: GestureDetector(
                      key: const Key('agents-workspace-switcher-barrier'),
                      behavior: HitTestBehavior.opaque,
                      onTap: toggleSwitcher,
                    ),
                  ),
                  Positioned(
                    left: 10,
                    right: 10,
                    top:
                        MessagingDesktopMetrics.conversationHeaderOverlayExtent,
                    bottom: 10,
                    child: _ConversationSwitcherPanel(
                      onDismiss: toggleSwitcher,
                      child: _sidebar(
                        agents,
                        native,
                        canonical,
                        tabActivity,
                        archive,
                        afterSelect: toggleSwitcher,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _sidebar(
    AgentsProjection agents,
    NativeConversationCatalogProjection native,
    CanonicalConversationProjection canonical,
    ConversationTabActivityProjection tabActivity,
    ConversationArchiveProjection archive, {
    bool avatarColumn = false,
    Widget? avatarColumnLeading,
    VoidCallback? afterSelect,
  }) {
    final selectedId = _selectedSession(native)?.id ?? '';
    final sessionsByAgent = <String, List<AgentConversationSession>>{
      for (final catalog in native.agentCatalogs)
        catalog.agentId: catalog.sessions,
      if (native.agentCatalogs.isEmpty && agents.selectedAgentId.isNotEmpty)
        agents.selectedAgentId: native.nativeSessions,
    };
    AgentConversationTabActivity activityFor(String agentId) =>
        _activityFor(tabActivity, agentId);
    bool runningFor(AgentConversationSession session) =>
        native.runningSessionIds.contains(session.id);
    void onSelectSession(String agentId, String sessionId) {
      afterSelect?.call();
      widget.agents.intents.send(
        SelectAgentConversationSession(agentId: agentId, sessionId: sessionId),
      );
    }

    void selectGroup(String conversationId) {
      afterSelect?.call();
      // A group row returns to the group chat directly, leaving any
      // member-session detail view.
      if (_showAgentDetailInsideGroupList) {
        setState(() => _showAgentDetailInsideGroupList = false);
      }
      widget.conversation.intents.send(
        SelectCanonicalConversation(conversationId),
      );
    }

    void createGroup() => unawaited(
      showCreateCanonicalGroupConversationDialog(
        context: context,
        intents: widget.conversation.intents,
        effects: widget.conversation.effects,
        targets: agents.targetDetails,
      ),
    );

    void createProfile() => unawaited(
      showConversationProfileCreateDialog(
        context: context,
        intents: widget.conversation.intents,
        effects: widget.conversation.effects,
        agentsIntents: widget.agents.intents,
        targets: agents.targetDetails,
        isRefreshingAgentCatalog: (agentId) =>
            agents.acativa.agent(agentId)?.refreshingModelCatalog ?? false,
      ),
    );

    void refreshSidebarCatalog() {
      // Read current projections, not the last rendered snapshot: a second
      // gesture must not redispatch during the frame before loading paints.
      if (widget.conversation.nativeCatalog.current.phase ==
              PresentationPhase.loading ||
          widget.conversation.canonicalEvents.current.phase ==
              PresentationPhase.loading) {
        return;
      }
      widget.conversation.intents.send(const RefreshConversationCatalog());
    }

    final sidebarRefreshing =
        native.phase == PresentationPhase.loading ||
        canonical.phase == PresentationPhase.loading;
    final strategy = LayoutAgentsStrategyScope.maybeOf(context);
    // The pinned avatar column is the same rail in every sidebar style — the
    // tree-style list must never be squeezed into the 64px column.
    if (avatarColumn ||
        strategy.sidebarStyle == AgentsSidebarStyle.flatRecencyList) {
      return MessagingContactList(
        targets: agents.targetDetails,
        sessionsByAgent: sessionsByAgent,
        selectedAgentId: agents.selectedAgentId,
        selectedSessionId: selectedId,
        groupConversations: canonical.groupConversations,
        directConversations: canonical.directConversations,
        selectedGroupConversationId: canonical.conversationId,
        onSelectGroupConversation: selectGroup,
        onSetGroupConversationPinned: (conversationId, pinned) => widget
            .conversation
            .intents
            .send(SetCanonicalConversationPinned(conversationId, pinned)),
        onArchiveGroupConversation: (conversationId) {
          if (canonical.conversationId == conversationId &&
              _showAgentDetailInsideGroupList) {
            setState(() => _showAgentDetailInsideGroupList = false);
          }
          widget.conversation.intents.send(ArchiveConversation(conversationId));
        },
        onNewGroupConversation: createGroup,
        onNewAgentProfile: createProfile,
        activityFor: activityFor,
        runningFor: runningFor,
        onSelectAgent: (agentId) {
          afterSelect?.call();
          widget.agents.intents.send(OpenAgentConversation(agentId));
        },
        onSelectAgentSession: onSelectSession,
        onNewConversation: () {
          afterSelect?.call();
          widget.conversation.intents.send(const StartConversationSession());
        },
        onSearch: widget.onSearch,
        onRefresh: refreshSidebarCatalog,
        onPrefetchSessions: (agentId) => widget.conversation.intents.send(
          RefreshConversationCatalog(agentId: agentId),
        ),
        isPinned: (targetId) {
          for (final target in agents.targets) {
            if (target.id == targetId) return target.pinned;
          }
          return false;
        },
        onTogglePinned: (agentId) =>
            widget.agents.intents.send(ToggleAgentPinned(agentId)),
        scanning: agents.scanning,
        loading: sidebarRefreshing,
        loadingAgentIds: native.loadingAgentIds.toSet(),
        loadingGroupConversationId: canonical.phase == PresentationPhase.loading
            ? canonical.conversationId
            : '',
        activeDestination: ClientSection.agents,
        onSelectDestination: widget.onSelectDestination,
        avatarColumn: avatarColumn,
        avatarColumnLeading: avatarColumnLeading,
      );
    }
    final nativeSidebar = AgentsWorkspaceSidebar(
      targets: agents.targetDetails,
      sessionsByAgent: sessionsByAgent,
      selectedSessionId: selectedId,
      activityFor: activityFor,
      runningFor: runningFor,
      onSelectSession: onSelectSession,
      onNewConversation: () =>
          widget.conversation.intents.send(const StartConversationSession()),
      onPrefetchSessions: (agentId) => widget.conversation.intents.send(
        RefreshConversationCatalog(agentId: agentId),
      ),
      onArchive: () => unawaited(
        showConversationArchiveDialog(
          context,
          actions: _archiveActions(archive),
          sourceAgentId: '',
        ),
      ),
      onAddTarget: widget.onAddTarget,
      onRefresh: refreshSidebarCatalog,
      scanning: agents.scanning,
      adding: agents.adding,
      refreshing: sidebarRefreshing,
      allowManualTargetActions: widget.allowManualTargetActions,
    );
    return Column(
      children: [
        CanonicalGroupConversationSidebar(
          conversations: canonical.groupConversations,
          selectedConversationId: canonical.conversationId,
          highlightedChildConversationId: canonical.conversationId,
          onSelect: selectGroup,
          onCreate: createGroup,
        ),
        Expanded(child: nativeSidebar),
      ],
    );
  }

  AgentConversationTabActivity _activityFor(
    ConversationTabActivityProjection projection,
    String agentId,
  ) {
    final normalized = agentId.trim();
    for (final activity in projection.agentActivities) {
      if (activity.agentId == normalized) return activity.activity;
    }
    return AgentConversationTabActivity.none;
  }

  ConversationArchiveActions _archiveActions(
    ConversationArchiveProjection projection,
  ) => ConversationArchiveActions(
    initialQuery: projection.queryDraft,
    destinationFor: (selectionMode, sourceAgentId) {
      final normalized = sourceAgentId.trim();
      ConversationArchiveDestinationProjection? selected;
      for (final destination in projection.backupDestinations) {
        if (destination.sourceAgentId == normalized) {
          selected = destination;
          break;
        }
      }
      if (selected == null) return '';
      return selectionMode == conversationArchiveAllSelection
          ? selected.allDestination
          : selected.exactKeywordDestination;
    },
    archiveAll: (sourceAgentId, destination) {
      widget.conversation.intents.send(
        BackupAllNativeConversations(
          sourceAgentId: sourceAgentId,
          destination: destination,
        ),
      );
    },
    archiveExactKeyword: (query, sourceAgentId, destination) {
      widget.conversation.intents.send(
        BackupNativeConversationsByExactKeyword(
          query: query,
          sourceAgentId: sourceAgentId,
          destination: destination,
        ),
      );
    },
  );

  Widget _nativeConversationPane(
    BuildContext context,
    TargetCandidate target,
    AgentConversationSession? session,
    NativeConversationCatalogProjection native,
    PersistentTurnProjection turns,
    ComposerProjection composer,
    ConversationAttachmentsProjection attachments, {
    required bool mobile,
    VoidCallback? onBackToGroup,
  }) {
    final turn = turns.memberships.isEmpty ? null : turns.memberships.first;
    final active =
        turn?.phase == PersistentTurnPhase.running ||
        turn?.phase == PersistentTurnPhase.waiting;
    final strings = LicoStrings.of(context);
    final strategy = LayoutAgentsStrategyScope.maybeOf(context);
    final showWorkingDirectory =
        !mobile && !target.hasValidVirtualMachineConnection;
    final composerEnabled =
        composer.inputEnabled && (turn?.inputEnabled ?? true);
    final gateReasonCode = composerEnabled
        ? (attachments.statusCode.isNotEmpty
              ? attachments.statusCode
              : turn?.failureReasonCode ?? native.notice?.reasonCode ?? '')
        : target.conversationSendGateReason;
    final unblockSend = switch (gateReasonCode) {
      'native_agent_executable_not_detected' ||
      'native_agent_runtime_profile_unavailable' ||
      'runtime_message_send_unavailable' => () => widget.agents.intents.send(
        const ScanAgents(),
      ),
      'antigravity_auth_required' => () => widget.conversation.intents.send(
        const AuthorizeConversationRuntime(),
      ),
      _ => null,
    };
    // Runtime-binding gate codes are provisional while a scan or the
    // selection-time executable binding is still in flight: the gate area
    // shows a loading indicator instead of a verdict that can resolve itself
    // moments later. A settled scan that still reports the code keeps the
    // honest unavailable row.
    final gateResolving =
        const {
          'native_agent_executable_not_detected',
          'native_agent_runtime_profile_unavailable',
          'runtime_message_send_unavailable',
        }.contains(gateReasonCode) &&
        (native.phase == PresentationPhase.loading ||
            widget.agents.projection.current.scanning);
    final state = AgentConversationPaneState(
      target: target,
      session: session,
      liveMessages: turn?.messages ?? const <AgentConversationMessage>[],
      recentSessions: native.nativeSessions,
      loading: native.phase == PresentationPhase.loading,
      recentSessionsHasMore: native.hasMore,
      recentSessionsLoadingMore: native.loadingMore,
      messagePageLoading: native.messagePageLoading,
      messagePageError: native.messagePageError,
      turnActive: active,
      inputEnabled: turn?.inputEnabled ?? true,
      cancelEnabled: turn?.cancelEnabled ?? false,
      preparingNewConversation: native.preparingNewConversation,
      composerEnabled: composerEnabled,
      sendGateReasonCode: gateReasonCode,
      sendGateResolving: gateResolving,
      composerDraft: composer.draft,
      hasAttachments: attachments.attachments.isNotEmpty,
      modelOptions: composer.modelOptions,
      selectedModel: composer.selectedModel,
      defaultModel: composer.defaultModel,
      reasoningEffortOptions: composer.reasoningEffortOptions,
      selectedReasoningEffort: composer.selectedReasoningEffort,
      defaultReasoningEffort: composer.defaultReasoningEffort,
      showWorkingDirectory: showWorkingDirectory,
      workingDirectory: showWorkingDirectory ? composer.workingDirectory : '',
      workingDirectorySelectable:
          showWorkingDirectory && composer.workingDirectorySelectable,
      sendAuthorizeActive: native.authorizingRuntime,
      permissionRetryTool: native.pendingPermissionRetryTool,
      participantTargets: widget.agents.projection.current.targetDetails,
      showLicoProfileCapsule: native.supportsLicoProfile,
      selectedLicoProfile: native.selectedLicoProfile,
      runningRecentSessionIds: native.runningSessionIds.toSet(),
      recentSessionsCached: native.nativeSessions.isNotEmpty,
    );
    final actions = AgentConversationPaneActions(
      onOpenExecution: (context, message, speakingTarget, returnFocusNode) =>
          unawaited(
            showBoundConversationExecution(
              context: context,
              message: message,
              target: speakingTarget,
              conversationTitle: session?.title ?? '',
              projection: widget.conversation.execution,
              intents: widget.conversation.intents,
              onCopyText: (text) async =>
                  widget.conversation.intents.send(CopyConversationText(text)),
              returnFocusNode: returnFocusNode,
            ),
          ),
      onModelChanged: (model) =>
          widget.conversation.intents.send(SelectConversationModel(model)),
      onReasoningEffortChanged: (reasoningEffort) => widget.conversation.intents
          .send(SelectConversationReasoningEffort(reasoningEffort)),
      onDraftChanged: (draft) => widget.conversation.intents.send(
        UpdateConversationDraft(composer.conversationId, draft),
      ),
      onPermissionRetry: () =>
          widget.conversation.intents.send(const RetryConversationPermission()),
      onPermissionRetryRemember: () => widget.conversation.intents.send(
        const RetryConversationPermission(remember: true),
      ),
      onPermissionDeny: () => widget.conversation.intents.send(
        const DismissConversationPermission(),
      ),
      onCopyText: (text) async =>
          widget.conversation.intents.send(CopyConversationText(text)),
      onSend: (content) async {
        widget.conversation.intents.send(
          PostConversationMessage(
            conversationId: composer.conversationId,
            content: content,
            addressedMembershipIds: [
              if (turn?.membershipId.trim().isNotEmpty == true)
                turn!.membershipId,
            ],
            dispatchCanonical: false,
          ),
        );
        return true;
      },
      onCancel: turn?.cancelEnabled == true
          ? () async => widget.conversation.intents.send(
              InterruptConversationTurn(
                composer.conversationId,
                turn!.membershipId,
              ),
            )
          : null,
      onSelectSession: (sessionId) => widget.conversation.intents.send(
        SelectConversationSession(sessionId),
      ),
      onNewConversation: () =>
          widget.conversation.intents.send(const StartConversationSession()),
      onLoadMoreRecentSessions: native.hasMore
          ? () => widget.conversation.intents.send(
              const LoadMoreConversationSessions(),
            )
          : null,
      onLoadEarlierMessages: () async => widget.conversation.intents.send(
        LoadEarlierConversationEvents(composer.conversationId),
      ),
      onUnblockSend: unblockSend,
      onChooseWorkingDirectory:
          showWorkingDirectory && composer.workingDirectorySelectable
          ? () => unawaited(_chooseWorkingDirectory(composer.workingDirectory))
          : null,
      onAttach:
          strategy.messageStyle == AgentsMessageStyle.participantFlow &&
              attachments.acceptsImages
          ? () => widget.conversation.intents.send(
              AddConversationAttachment(composer.conversationId),
            )
          : null,
      onPasteImage:
          strategy.messageStyle == AgentsMessageStyle.participantFlow &&
              attachments.acceptsImages
          ? () async {
              widget.conversation.intents.send(
                PasteConversationAttachment(composer.conversationId),
              );
              return true;
            }
          : null,
      onLicoProfileChanged: native.supportsLicoProfile
          ? (profile) => widget.conversation.intents.send(
              SelectConversationLicoProfile(profile),
            )
          : null,
    );
    final serveState = native.opencodeServeStatus.trim().isEmpty
        ? null
        : AgentConversationServeState(
            status: switch (native.opencodeServeStatus.trim()) {
              'running' => AgentConversationServeStatus.running,
              'blocked' => AgentConversationServeStatus.blocked,
              'unavailable' => AgentConversationServeStatus.unavailable,
              _ => AgentConversationServeStatus.stopped,
            },
            port: native.opencodeServePort,
            portConflict: native.opencodeServePortConflict,
          );
    final headerState = AgentConversationHeaderState(
      target: target,
      session: session,
      historyCollapsed: _sidebarCollapsed,
      collapseHistoryTooltip: strings.collapseHistoryConversations,
      expandHistoryTooltip: strings.expandHistoryConversations,
      opencodeServeState: serveState,
    );
    final headerActions = AgentConversationHeaderActions(
      onToggleHistory: _toggleSidebarCollapsed,
    );
    final header = strategy.messageStyle == AgentsMessageStyle.participantFlow
        ? MessagingConversationHeader(
            target: target,
            session: session,
            detailsState: state,
            detailsActions: actions,
            opencodeServeState: serveState,
            historySessions: native.nativeSessions,
            historySelectedSessionId: session?.id ?? '',
            onSelectHistorySession: (sessionId) => widget.conversation.intents
                .send(SelectConversationSession(sessionId)),
            // The member-session view inside a group must not offer a
            // detached new conversation; the roster history omits it too.
            onNewHistoryConversation: onBackToGroup == null
                ? () => widget.conversation.intents.send(
                    const StartConversationSession(),
                  )
                : null,
            historyRunningFor: (candidate) =>
                native.runningSessionIds.contains(candidate.id),
            onBackToGroup: onBackToGroup,
          )
        : ConversationPaneHeader(state: headerState, actions: headerActions);
    return NativeSubagentHistoryScope(
      key: ValueKey(
        'native-children-${target.target}-${session?.nativeSessionId ?? ''}',
      ),
      histories: native.childHistories,
      onLoad: (childId, earlier) => widget.conversation.intents.send(
        LoadChildConversationMessages(childId, earlier: earlier),
      ),
      child: AgentConversationActivePane(
        state: state,
        actions: actions,
        header: header,
        framed: mobile,
      ),
    );
  }

  TargetCandidate? _selectedTarget(AgentsProjection projection) {
    for (final target in projection.targetDetails) {
      if (target.id == projection.selectedAgentId ||
          target.target == projection.selectedAgentId) {
        return target;
      }
    }
    return null;
  }

  AgentConversationSession? _selectedSession(
    NativeConversationCatalogProjection projection,
  ) {
    final selected = {
      for (final item in projection.sessions)
        if (item.selected) item.id,
    };
    for (final session in projection.nativeSessions) {
      if (selected.contains(session.id)) return session;
    }
    return null;
  }
}

class _EmptyConversation extends StatelessWidget {
  const _EmptyConversation({this.onAddTarget});

  final VoidCallback? onAddTarget;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final colors = context.licoColors;
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
            if (onAddTarget != null) ...[
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

/// The rail's expand control above its avatars.
final class _AvatarRailExpandControl extends StatelessWidget {
  const _AvatarRailExpandControl({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final label = strings.isChinese ? '展开侧栏' : 'Expand the sidebar';
    return SizedBox(
      height: MessagingDesktopMetrics.conversationHeaderOverlayExtent,
      child: Center(
        child: Tooltip(
          message: label,
          waitDuration: LicoMotion.tooltipWait,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              key: const Key('agents-workspace-rail-expand'),
              onTap: onTap,
              customBorder: const CircleBorder(),
              child: SizedBox.square(
                dimension: 36,
                child: Icon(
                  Icons.keyboard_double_arrow_left_rounded,
                  size: 18,
                  color: colors.textMuted,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The header switcher's full conversation list, floating over the detail.
/// Escape closes it; the barrier behind it closes it on outside clicks.
final class _ConversationSwitcherPanel extends StatelessWidget {
  const _ConversationSwitcherPanel({
    required this.onDismiss,
    required this.child,
  });

  final VoidCallback onDismiss;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): onDismiss,
      },
      child: Focus(
        autofocus: true,
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: 1),
          duration: context.motion(LicoMotion.short),
          curve: LicoMotion.decelerate,
          builder: (context, t, child) => Opacity(
            opacity: t,
            child: Transform.translate(
              offset: Offset(0, -6 * (1 - t)),
              child: child,
            ),
          ),
          child: MessagingConversationOverlayGlass(
            key: const Key('agents-workspace-switcher-panel'),
            readabilityVeil: true,
            borderRadius: BorderRadius.circular(
              MessagingDesktopMetrics.conversationListCardCornerRadius,
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(
                MessagingDesktopMetrics.conversationListCardCornerRadius,
              ),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}
