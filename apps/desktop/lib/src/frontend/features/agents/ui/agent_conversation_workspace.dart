import 'dart:async';

import 'package:licoup/src/frontend/features/agents/ui/conversation_execution_binding_viewer.dart';
import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:presentation_contract/presentation_contract.dart';
import 'package:presentation_flutter/presentation_flutter.dart';
import 'package:path/path.dart' as p;

import 'package:licoup/src/contracts/agent_conversation_attachment.dart';
import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/agent_conversation_tab_activity.dart';
import 'package:licoup/src/contracts/client_conversation_models.dart';
import 'package:licoup/src/contracts/presentation/layout_state_namespace.dart';
import 'package:licoup/src/frontend/layout/layout_state_port.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_display_names.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_layout_metrics.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_pane.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_message_blocks/native_subagent_history_scope.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_workspace_sidebar.dart';
import 'package:licoup/src/frontend/features/agents/ui/conversation_archive_dialog.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_contact_list.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_conversation_header.dart';
import 'package:licoup/src/frontend/features/mobile_relay/ui/secure_mesh_approval_card.dart';
import 'package:licoup/src/frontend/features/agents/ui/conversation/canonical_group_conversation_pane.dart';
import 'package:licoup/src/frontend/features/agents/ui/conversation/conversation_plane_builder.dart';
import 'package:licoup/src/frontend/features/agents/ui/conversation/conversation_plane_projection_source.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_agents_directive.dart';
import 'package:licoup/src/frontend/layout/layout_agents_strategy.dart';
import 'package:licoup/src/frontend/layout/layout_destination_presentation.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/layout/layout_scope.dart';
import 'package:licoup/src/frontend/shared/messaging/external_conversation_composer.dart';
import 'package:licoup/src/frontend/shared/messaging/messaging_sidebar_column.dart';
import 'package:licoup/src/frontend/shared/platform/client_platform.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/agents/agents_binding.dart';
import 'package:licoup/src/presentation/agents/agents_intent.dart';
import 'package:licoup/src/presentation/agents/agents_projection.dart';
import 'package:licoup/src/presentation/agents/agents_providers.dart';
import 'package:licoup/src/presentation/conversation/conversation_binding.dart';
import 'package:licoup/src/presentation/conversation/conversation_effect.dart';
import 'package:licoup/src/presentation/conversation/conversation_intent.dart';
import 'package:licoup/src/presentation/conversation/conversation_execution_projection.dart';
import 'package:licoup/src/presentation/conversation/conversation_projection.dart';
import 'package:licoup/src/presentation/conversation/conversation_source_port.dart';

import 'package:licoup/src/presentation/mobile_relay/mobile_relay_binding.dart';
import 'package:licoup/src/presentation/mobile_relay/mobile_relay_inputs.dart';
import 'package:licoup/src/presentation/mobile_relay/mobile_relay_intent.dart';
import 'package:licoup/src/presentation/mobile_relay/mobile_relay_projection.dart';
import 'package:licoup/src/presentation/mobile_relay/mobile_relay_providers.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';

const _conversationAttachmentMediaUnsupported = 'attachment_media_unsupported';

class AgentConversationWorkspace extends StatefulWidget {
  const AgentConversationWorkspace({
    super.key,
    required this.agents,
    required this.conversation,
    required this.relay,
    required this.onAddTarget,
    this.onSelectDestination,
    this.onSearch,
    this.allowManualTargetActions = true,
  });

  final AgentsBinding agents;
  final ConversationBinding conversation;
  final MobileRelayBinding relay;
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
  bool _showWelcome = false;
  String _conversationListAgentId = '';
  String _conversationListGroupId = '';
  bool _showAgentDetailInsideGroupList = false;
  String? _observedConversationSelection;
  String _warmedBrowseCatalogSignature = '';
  bool _localGroupAutoSelected = false;
  final List<({String agentId, String groupId})> _conversationListHistory = [];

  ({String agentId, String groupId}) get _conversationListLocation =>
      (agentId: _conversationListAgentId, groupId: _conversationListGroupId);

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

  void _applyConversationListLocation(
    ({String agentId, String groupId}) location,
  ) {
    _conversationListAgentId = location.agentId;
    _conversationListGroupId = location.groupId;
  }

  void _syncConversationListWithSelection(
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
    if (groupId.isNotEmpty) {
      if (canonical.conversation != null) {
        _showWelcome = false;
        _applyConversationListLocation((agentId: '', groupId: groupId));
      }
    } else if (agentId.isNotEmpty && sessionId.isNotEmpty) {
      _showWelcome = false;
      _applyConversationListLocation((agentId: agentId, groupId: ''));
    } else if (agentId.isEmpty) {
      _applyConversationListLocation((agentId: '', groupId: ''));
    }
  }

  /// Layout-directed default: shells that always show a conversation (the
  /// Desktop split workspace) ask the workspace to open the pinned Local
  /// group once whenever it settles with nothing selected. A restored or
  /// user-driven selection always wins; the request fires at most once per
  /// mount so an explicit deselect (welcome page) is never overridden.
  void _selectLocalGroupWhenIdle(
    ConversationProjection root,
    CanonicalConversationProjection canonical,
    AgentsProjection agents,
  ) {
    if (_localGroupAutoSelected || _showWelcome) return;
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

  void _showAgentConversationList(String agentId) {
    final next = (agentId: agentId, groupId: '');
    if (_conversationListLocation == next) return;
    setState(() {
      _showWelcome = false;
      _showAgentDetailInsideGroupList = false;
      _conversationListHistory.add(_conversationListLocation);
      _applyConversationListLocation(next);
    });
  }

  void _showGroupConversationList(String conversationId) {
    final next = (agentId: '', groupId: conversationId);
    if (_conversationListLocation == next) return;
    setState(() {
      _showWelcome = false;
      _showAgentDetailInsideGroupList = false;
      _conversationListHistory.add(_conversationListLocation);
      _applyConversationListLocation(next);
    });
  }

  void _returnToPreviousConversationList() {
    if (_showAgentDetailInsideGroupList &&
        _conversationListGroupId.isNotEmpty) {
      final groupId = _conversationListGroupId;
      setState(() => _showAgentDetailInsideGroupList = false);
      widget.conversation.intents.send(SelectCanonicalConversation(groupId));
      return;
    }
    final previous = _conversationListHistory.isEmpty
        ? (agentId: '', groupId: '')
        : _conversationListHistory.removeLast();
    setState(() {
      _showAgentDetailInsideGroupList = false;
      _applyConversationListLocation(previous);
    });
    if (previous.groupId.isNotEmpty) {
      widget.conversation.intents.send(
        SelectCanonicalConversation(previous.groupId),
      );
    } else if (previous.agentId.isNotEmpty) {
      widget.conversation.intents.send(
        const ClearCanonicalConversationSelection(),
      );
      widget.agents.intents.send(SelectAgent(previous.agentId));
    }
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

  void _openAgentConversationHome(String agentId) {
    _showAgentConversationList(agentId);
    widget.agents.intents.send(StartAgentConversation(agentId));
  }

  void _showWelcomePage() {
    setState(() {
      _showWelcome = true;
      _showAgentDetailInsideGroupList = false;
      _conversationListHistory.clear();
      _applyConversationListLocation((agentId: '', groupId: ''));
    });
    widget.agents.intents.send(const ShowAgentsWelcome());
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

  void _showCreateGroup(AgentsProjection agents) {
    unawaited(
      showCreateCanonicalGroupConversationDialog(
        context: context,
        intents: widget.conversation.intents,
        effects: widget.conversation.effects,
        targets: agents.targetDetails,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final planes = conversationSourcePortOf(context);
    // Only the planes a conversation's identity depends on gate the frame.
    // Every other plane is consumed where it is visible, so losing authority
    // over the composer or a tab badge never hides authorized history.
    return AsyncRegion<AgentsProjection, IntentSink<AgentsIntent>>(
      source: agentsCatalogProjectionProvider,
      actions: widget.agents.intents,
      data: (context, agents, _) =>
          ConversationPlaneSurface<
            ConversationProjection,
            ConversationProjection
          >(
            plane: planes.projection,
            select: (projection) => projection,
            builder: (context, root) =>
                ConversationPlaneSurface<
                  NativeConversationCatalogProjection,
                  NativeConversationCatalogProjection
                >(
                  plane: planes.nativeCatalog,
                  select: (projection) => projection,
                  builder: (context, native) =>
                      ConversationPlaneSurface<
                        CanonicalConversationProjection,
                        CanonicalConversationProjection
                      >(
                        plane: planes.canonicalEvents,
                        select: (projection) => projection,
                        builder: (context, canonical) =>
                            ConversationPlaneSurface<
                              PersistentTurnProjection,
                              PersistentTurnProjection
                            >(
                              plane: planes.persistentTurns,
                              select: (projection) => projection,
                              builder: (context, turns) =>
                                  AsyncRegion<
                                    MobileRelayApprovalsInputs,
                                    IntentSink<MobileRelayIntent>
                                  >(
                                    source: mobileRelayApprovalsInputsProvider,
                                    actions: widget.relay.intents,
                                    data: (context, relay, _) =>
                                        _buildWorkspace(
                                          context,
                                          agents,
                                          planes,
                                          root,
                                          native,
                                          canonical,
                                          turns,
                                          relay,
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
    ConversationSourcePort planes,
    ConversationProjection root,
    NativeConversationCatalogProjection native,
    CanonicalConversationProjection canonical,
    PersistentTurnProjection turns,
    MobileRelayApprovalsInputs relay,
  ) {
    _syncConversationListWithSelection(agents, root, native, canonical);
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
    final externalComposerHosted =
        !mobile &&
        LayoutExternalComposerScope.isHosted(context) &&
        LayoutAgentsStrategyScope.maybeOf(context).messageStyle ==
            AgentsMessageStyle.participantFlow;
    final canonicalDetail =
        root.authority == ConversationAuthority.canonicalConversation &&
        !_showAgentDetailInsideGroupList;
    final detail = canonicalDetail
        // Composer and attachments are nullable planes now: a withdrawal only
        // disables its own region (draft/send/mention or attachments) while
        // the canonical history, sidebar, and roster stay visible from their
        // own admitted planes.
        ? ConversationPlaneValue<ComposerProjection>(
            plane: planes.composer,
            builder: (context, _) =>
                ConversationPlaneValue<ConversationAttachmentsProjection>(
                  plane: planes.attachments,
                  builder: (context, _) => CanonicalGroupConversationPane(
                    conversation: widget.conversation,
                    agents: widget.agents,
                    canonical: canonical,
                    turns: turns,
                    composer: planes.composer.visibleValue,
                    attachments: planes.attachments.visibleValue,
                    allTargets: agents.targetDetails,
                    framed: mobile,
                    onOpenAgentConversations: (agentId) {
                      _showAgentConversationList(agentId);
                      widget.conversation.intents.send(
                        const ClearCanonicalConversationSelection(),
                      );
                      widget.agents.intents.send(SelectAgent(agentId));
                    },
                  ),
                ),
          )
        : _showWelcome
        ? AgentConversationWelcome(
            onNewConversation: agents.targetDetails.isEmpty
                ? null
                : () {
                    setState(() => _showWelcome = false);
                    widget.agents.intents.send(
                      StartAgentConversation(agents.targetDetails.first.id),
                    );
                  },
            onNewGroupConversation: () => _showCreateGroup(agents),
            onOpenMobilePairing: () =>
                widget.onSelectDestination?.call(ClientSection.mobileRelay),
            onOpenSettings: () =>
                widget.onSelectDestination?.call(ClientSection.settings),
          )
        : selectedTarget == null
        ? _EmptyConversation(
            onAddTarget: widget.allowManualTargetActions
                ? widget.onAddTarget
                : null,
          )
        : ConversationPlaneValue<ComposerProjection>(
            plane: planes.composer,
            builder: (context, composer) =>
                ConversationPlaneValue<ConversationAttachmentsProjection>(
                  plane: planes.attachments,
                  builder: (context, attachments) => _nativeConversationPane(
                    context,
                    agents,
                    selectedTarget,
                    selectedSession,
                    native,
                    turns,
                    composer,
                    attachments,
                    planes.execution,
                    mobile: mobile,
                  ),
                ),
          );
    final hostsInternalComposer =
        canonicalDetail || (!_showWelcome && selectedTarget != null);
    final relocatedDetail = externalComposerHosted && hostsInternalComposer
        ? ExternalConversationComposerClip(child: detail)
        : detail;

    final pendingApprovals = relay.approvals.where(
      (approval) => approval.state == RelayApprovalState.pending,
    );
    final decoratedDetail = pendingApprovals.isEmpty
        ? relocatedDetail
        : Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
                child: SecureMeshApprovalCard.inputs(
                  inputs: relay,
                  intents: widget.relay.intents,
                ),
              ),
              Expanded(child: relocatedDetail),
            ],
          );
    if (mobile) return decoratedDetail;

    final sidebar = _sidebar(agents, native, canonical, planes);
    return ColoredBox(
      key: const Key('agents-workspace-shell'),
      color: presentation.canvasColor(context.layoutPalette),
      child: LayoutBuilder(
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
            child: decoratedDetail,
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
      ),
    );
  }

  Widget _sidebar(
    AgentsProjection agents,
    NativeConversationCatalogProjection native,
    CanonicalConversationProjection canonical,
    ConversationSourcePort planes,
  ) {
    // Tab badges and the archive affordance are local planes: losing authority
    // over one of them degrades that affordance and never the sidebar list or
    // the conversations it still shows.
    return ConversationPlaneValue<ConversationTabActivityProjection>(
      plane: planes.tabActivity,
      builder: (context, tabActivity) =>
          ConversationPlaneValue<ConversationArchiveProjection>(
            plane: planes.archive,
            builder: (context, archive) => _buildSidebarBody(
              agents,
              planes,
              native,
              canonical,
              tabActivity,
              archive,
            ),
          ),
    );
  }

  Widget _buildSidebarBody(
    AgentsProjection agents,
    ConversationSourcePort planes,
    NativeConversationCatalogProjection native,
    CanonicalConversationProjection canonical,
    ConversationTabActivityProjection? tabActivity,
    ConversationArchiveProjection? archive,
  ) {
    final selectedId = _selectedSession(native)?.id ?? '';
    var showConversationList = false;
    var conversationListTargets = const <TargetCandidate>[];
    var conversationListPriorityAgentId = '';
    var showConversationAgentIcons = false;
    if (_conversationListGroupId.isNotEmpty) {
      showConversationList = true;
      final selectedGroup = canonical.conversation;
      if (selectedGroup != null &&
          selectedGroup.id == _conversationListGroupId) {
        conversationListTargets = agents.targetDetails
            .where((target) => target.isConversationAgent)
            .toList(growable: false);
        conversationListPriorityAgentId =
            selectedGroup.assistantMembership?.principal.agentId.trim() ?? '';
      }
      showConversationAgentIcons = true;
    } else if (_conversationListAgentId.isNotEmpty) {
      TargetCandidate? representative;
      for (final candidate in agents.targetDetails) {
        if (candidate.id == _conversationListAgentId ||
            candidate.target == _conversationListAgentId) {
          representative = candidate;
          break;
        }
      }
      if (representative != null) {
        showConversationList = true;
        final productId = agentConversationProductId(representative.target);
        conversationListTargets = agents.targetDetails
            .where(
              (candidate) =>
                  candidate.isConversationAgent &&
                  agentConversationProductId(candidate.target) == productId,
            )
            .toList(growable: false);
      }
    }
    final sessionsByAgent = _conversationListGroupId.isNotEmpty
        ? (native.groupConversationId == _conversationListGroupId
              ? native.groupSessionsByAgent
              : const <String, List<AgentConversationSession>>{})
        : <String, List<AgentConversationSession>>{
            for (final catalog in native.agentCatalogs)
              catalog.agentId: catalog.sessions,
            if (native.agentCatalogs.isEmpty &&
                agents.selectedAgentId.isNotEmpty)
              agents.selectedAgentId: native.nativeSessions,
          };
    AgentConversationTabActivity activityFor(String agentId) =>
        _activityFor(tabActivity, agentId);
    bool runningFor(AgentConversationSession session) =>
        native.runningSessionIds.contains(session.id);
    void onSelectSession(String agentId, String sessionId) {
      setState(() => _showWelcome = false);
      if (_conversationListGroupId.isNotEmpty) {
        final groupId = _conversationListGroupId;
        setState(() => _showAgentDetailInsideGroupList = true);
        widget.agents.intents.send(
          SelectGroupAgentConversationSession(
            groupConversationId: groupId,
            agentId: agentId,
            sessionId: sessionId,
          ),
        );
        return;
      }
      widget.agents.intents.send(
        SelectAgentConversationSession(agentId: agentId, sessionId: sessionId),
      );
    }

    void selectGroup(String conversationId) {
      _showGroupConversationList(conversationId);
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

    void refreshSidebarCatalog() {
      // Read current projections, not the last rendered snapshot: a second
      // gesture must not redispatch during the frame before loading paints.
      if (planes.nativeCatalog.visibleValue?.phase ==
              PresentationPhase.loading ||
          planes.canonicalEvents.visibleValue?.phase ==
              PresentationPhase.loading) {
        return;
      }
      widget.conversation.intents.send(const RefreshConversationCatalog());
    }

    final sidebarRefreshing =
        native.phase == PresentationPhase.loading ||
        canonical.phase == PresentationPhase.loading;
    final strategy = LayoutAgentsStrategyScope.maybeOf(context);
    if (strategy.sidebarStyle == AgentsSidebarStyle.flatRecencyList) {
      return MessagingContactList(
        targets: agents.targetDetails,
        sessionsByAgent: sessionsByAgent,
        selectedAgentId: agents.selectedAgentId,
        groupConversations: canonical.groupConversations,
        selectedGroupConversationId: canonical.conversationId,
        onSelectGroupConversation: selectGroup,
        onSetGroupConversationPinned: (conversationId, pinned) => widget
            .conversation
            .intents
            .send(SetCanonicalConversationPinned(conversationId, pinned)),
        onArchiveGroupConversation: (conversationId) {
          if (_conversationListGroupId == conversationId) {
            setState(() {
              _showAgentDetailInsideGroupList = false;
              _conversationListHistory.clear();
              _applyConversationListLocation((agentId: '', groupId: ''));
            });
          }
          widget.conversation.intents.send(ArchiveConversation(conversationId));
        },
        onNewGroupConversation: createGroup,
        activityFor: activityFor,
        runningFor: runningFor,
        onSelectAgent: _openAgentConversationHome,
        onNewConversation: () =>
            widget.conversation.intents.send(const StartConversationSession()),
        onSearch: widget.onSearch,
        onRefresh: refreshSidebarCatalog,
        onOpenWelcome: _showWelcomePage,
        showConversationList: showConversationList,
        conversationListTargets: conversationListTargets,
        selectedSessionId: selectedId,
        showConversationAgentIcons: showConversationAgentIcons,
        onSelectSession: onSelectSession,
        onBack: _returnToPreviousConversationList,
        onPrefetchSessions: _conversationListGroupId.isNotEmpty
            ? null
            : (agentId) => widget.conversation.intents.send(
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
        priorityAgentId: conversationListPriorityAgentId,
        scanning: agents.scanning,
        loading: sidebarRefreshing,
        activeDestination: ClientSection.agents,
        onSelectDestination: widget.onSelectDestination,
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
      onPrefetchSessions: _conversationListGroupId.isNotEmpty
          ? null
          : (agentId) => widget.conversation.intents.send(
              RefreshConversationCatalog(agentId: agentId),
            ),
      onArchive: archive == null
          ? null
          : () => unawaited(
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
    ConversationTabActivityProjection? projection,
    String agentId,
  ) {
    if (projection == null) return AgentConversationTabActivity.none;
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
    AgentsProjection agents,
    TargetCandidate target,
    AgentConversationSession? session,
    NativeConversationCatalogProjection native,
    PersistentTurnProjection turns,
    ComposerProjection? composer,
    ConversationAttachmentsProjection? attachments,
    ConversationPlanePort<ConversationExecutionProjection>? executionPlane, {
    required bool mobile,
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
        composer != null &&
        composer.inputEnabled &&
        (turn?.inputEnabled ?? true);
    final attachmentStatusCode = attachments?.statusCode ?? '';
    final gateReasonCode = composerEnabled
        ? (attachmentStatusCode.isNotEmpty
              ? attachmentStatusCode
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
      composerDraft: composer?.draft ?? '',
      hasAttachments: attachments?.attachments.isNotEmpty ?? false,
      modelOptions: composer?.modelOptions ?? const <String>[],
      selectedModel: composer?.selectedModel ?? '',
      defaultModel: composer?.defaultModel ?? '',
      reasoningEffortOptions:
          composer?.reasoningEffortOptions ?? const <String>[],
      selectedReasoningEffort: composer?.selectedReasoningEffort ?? '',
      defaultReasoningEffort: composer?.defaultReasoningEffort ?? '',
      showWorkingDirectory: showWorkingDirectory,
      workingDirectory: showWorkingDirectory
          ? (composer?.workingDirectory ?? '')
          : '',
      workingDirectorySelectable:
          showWorkingDirectory &&
          (composer?.workingDirectorySelectable ?? false),
      sendAuthorizeActive: native.authorizingRuntime,
      permissionRetryTool: native.pendingPermissionRetryTool,
      participantTargets: agents.targetDetails,
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
              projection: executionPlane == null
                  ? null
                  : ConversationPlaneProjectionSource<
                      ConversationExecutionProjection
                    >(
                      executionPlane,
                      empty: ConversationExecutionProjection.new,
                    ),
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
      onDraftChanged: (draft) {
        final conversationId = composer?.conversationId ?? '';
        if (conversationId.isEmpty) return;
        widget.conversation.intents.send(
          UpdateConversationDraft(conversationId, draft),
        );
      },
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
        final conversationId = composer?.conversationId ?? '';
        if (conversationId.isEmpty) return true;
        widget.conversation.intents.send(
          PostConversationMessage(
            conversationId: conversationId,
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
      onCancel: turn?.cancelEnabled == true && composer != null
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
      onLoadEarlierMessages: () async {
        final conversationId = composer?.conversationId ?? '';
        if (conversationId.isEmpty) return;
        widget.conversation.intents.send(
          LoadEarlierConversationEvents(conversationId),
        );
      },
      onUnblockSend: unblockSend,
      onChooseWorkingDirectory:
          showWorkingDirectory &&
              (composer?.workingDirectorySelectable ?? false)
          ? () => unawaited(
              _chooseWorkingDirectory(composer?.workingDirectory ?? ''),
            )
          : null,
      onAttach:
          strategy.messageStyle == AgentsMessageStyle.participantFlow &&
              (attachments?.acceptsImages ?? false) &&
              composer != null
          ? () => widget.conversation.intents.send(
              AddConversationAttachment(composer.conversationId),
            )
          : null,
      onPasteImage:
          strategy.messageStyle == AgentsMessageStyle.participantFlow &&
              (attachments?.acceptsImages ?? false) &&
              composer != null
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
            switcherSessions: native.nativeSessions,
            switcherSelectedSessionId: session?.id ?? '',
            onSwitchConversation: (sessionId) => widget.conversation.intents
                .send(SelectConversationSession(sessionId)),
            onSwitchNewConversation: () => widget.conversation.intents.send(
              const StartConversationSession(),
            ),
            switcherRunningFor: (candidate) =>
                native.runningSessionIds.contains(candidate.id),
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

/// Subscribes to one conversation plane for a surface that must distinguish a
/// first frame from a withdrawal: a plane that was never read renders its
/// loading state, a withdrawn plane renders its unavailable state, and a
/// visible plane renders the selected value. No value is ever revived.
class ConversationPlaneSurface<T, S> extends StatefulWidget {
  const ConversationPlaneSurface({
    super.key,
    required this.plane,
    required this.select,
    required this.builder,
    this.loading,
    this.unavailable,
  });

  final ConversationPlanePort<T> plane;
  final S Function(T value) select;
  final Widget Function(BuildContext context, S selected) builder;
  final WidgetBuilder? loading;
  final WidgetBuilder? unavailable;

  @override
  State<ConversationPlaneSurface<T, S>> createState() =>
      _ConversationPlaneSurfaceState<T, S>();
}

class _ConversationPlaneSurfaceState<T, S>
    extends State<ConversationPlaneSurface<T, S>> {
  StreamSubscription<ConversationPlaneRead<T>>? _subscription;
  T? _value;
  bool _withdrawn = false;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void didUpdateWidget(covariant ConversationPlaneSurface<T, S> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.plane, widget.plane)) {
      _subscription?.cancel();
      _subscribe();
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _subscription = null;
    super.dispose();
  }

  void _subscribe() {
    _value = widget.plane.visibleValue;
    _withdrawn = false;
    _subscription = widget.plane.reads.listen(_handleRead);
  }

  void _handleRead(ConversationPlaneRead<T> read) {
    if (!mounted) return;
    switch (read) {
      case ConversationPlaneVisible<T>(:final value):
        setState(() {
          _value = value;
          _withdrawn = false;
        });
      case ConversationPlaneWithdrawn<T>():
        setState(() {
          _value = null;
          _withdrawn = true;
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final value = _value;
    if (value != null) return widget.builder(context, widget.select(value));
    if (_withdrawn) {
      return (widget.unavailable ?? widget.loading)?.call(context) ??
          const SizedBox.shrink();
    }
    return widget.loading?.call(context) ?? const SizedBox.shrink();
  }
}

/// Subscribes to one local conversation plane and always builds, passing null
/// while the plane is invisible. A local plane degrades its own affordance and
/// never gates the surface around it.
class ConversationPlaneValue<T> extends StatefulWidget {
  const ConversationPlaneValue({
    super.key,
    required this.plane,
    required this.builder,
  });

  final ConversationPlanePort<T> plane;
  final Widget Function(BuildContext context, T? value) builder;

  @override
  State<ConversationPlaneValue<T>> createState() =>
      _ConversationPlaneValueState<T>();
}

class _ConversationPlaneValueState<T> extends State<ConversationPlaneValue<T>> {
  StreamSubscription<ConversationPlaneRead<T>>? _subscription;
  T? _value;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void didUpdateWidget(covariant ConversationPlaneValue<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.plane, widget.plane)) {
      _subscription?.cancel();
      _subscribe();
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _subscription = null;
    super.dispose();
  }

  void _subscribe() {
    _value = widget.plane.visibleValue;
    _subscription = widget.plane.reads.listen((read) {
      if (!mounted) return;
      setState(() {
        _value = switch (read) {
          ConversationPlaneVisible<T>(:final value) => value,
          ConversationPlaneWithdrawn<T>() => null,
        };
      });
    });
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _value);
}
