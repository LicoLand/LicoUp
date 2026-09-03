import 'dart:async';
import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/application/features/agents/contracts/agent_conversation_gateway.dart';
import 'package:licoup/src/application/features/conversations/client_conversation_controller.dart';
import 'package:licoup/src/application/features/layout/layout_state_store.dart';
import 'package:licoup/src/contracts/agent_conversation_attachment.dart';
import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/conversation_image_byte_reader.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/contracts/presentation/layout_state_namespace.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/layout/layout_agents_strategy.dart';
import 'package:licoup/src/frontend/layout/layout_destination_presentation.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/layout/layout_scope.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/shell/messaging_sidebar_column.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_pane.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_pane_controls.dart';
import 'package:licoup/src/frontend/features/agents/ui/adaptive_flywheel_dialog.dart';
import 'package:licoup/src/frontend/features/agents/ui/conversation_archive_dialog.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_composer.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_display_names.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_layout_metrics.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_message_display.dart';
import 'package:licoup/src/frontend/features/mobile_relay/ui/secure_mesh_approval_card.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_image_attachments.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_session_presentation.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_details_panel.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_workspace_sidebar.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_contact_list.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_conversation_header.dart';
import 'package:licoup/src/frontend/features/conversations/canonical_group_conversation_pane.dart';
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
    this.onSearch,
    this.allowManualTargetActions = true,
  });

  final ClientController controller;
  final List<TargetCandidate> targets;
  final bool scanning;
  final bool adding;
  final VoidCallback onAddTarget;
  final VoidCallback? onSearch;
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
    widget.controller.conversationStateHolder.addListener(
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
    oldWidget.controller.conversationStateHolder.removeListener(
      _handleControllerChanged,
    );
    widget.controller.addListener(_handleControllerChanged);
    widget.controller.conversationStructureListenable.addListener(
      _handleControllerChanged,
    );
    widget.controller.activeConversationListenable.addListener(
      _handleControllerChanged,
    );
    widget.controller.conversationStateHolder.addListener(
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
    widget.controller.conversationStateHolder.removeListener(
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
      onSearch: widget.onSearch,
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
    this.onSearch,
    required this.allowManualTargetActions,
    this.useFloatingShell = false,
  });

  final ClientController controller;
  final List<TargetCandidate> targets;
  final bool scanning;
  final bool adding;
  final VoidCallback onAddTarget;
  final VoidCallback? onSearch;
  final bool allowManualTargetActions;
  final bool useFloatingShell;

  @override
  State<_ConversationWorkspaceBody> createState() =>
      _ConversationWorkspaceBodyState();
}

class _ConversationWorkspaceBodyState
    extends State<_ConversationWorkspaceBody> {
  bool _historyCollapsed = false;
  bool _pickingConversationAttachments = false;
  // Default to the narrowest usable rail; users can drag wider.
  double _sidebarWidth = agentsSidebarMinWidth;
  LayoutScopedState? _layoutState;
  String? _layoutStateIdentity;
  String _conversationListAgentId = '';
  String _conversationListGroupId = '';
  bool _showAgentDetailInsideGroupList = false;
  String? _observedConversationSelection;
  final List<({String agentId, String groupId})> _conversationListHistory = [];

  ({String agentId, String groupId}) get _conversationListLocation =>
      (agentId: _conversationListAgentId, groupId: _conversationListGroupId);

  void _applyConversationListLocation(
    ({String agentId, String groupId}) location,
  ) {
    _conversationListAgentId = location.agentId;
    _conversationListGroupId = location.groupId;
  }

  void _syncConversationListWithSelection(ClientController controller) {
    final groupId = controller
        .clientConversationController
        .selectedConversationId
        .trim();
    final agentId = controller.selectedConversationAgentId.trim();
    final sessionId = controller.selectedConversationSessionId.trim();
    final selection = groupId.isNotEmpty
        ? 'group:$groupId'
        : agentId.isNotEmpty
        ? 'agent:$agentId:$sessionId'
        : '';
    if (_observedConversationSelection == selection) return;
    _observedConversationSelection = selection;
    if (groupId.isNotEmpty) {
      final hasBody =
          controller.clientConversationController.selectedConversation != null;
      if (hasBody) {
        _applyConversationListLocation((agentId: '', groupId: groupId));
      }
    } else if (agentId.isNotEmpty && sessionId.isNotEmpty) {
      _applyConversationListLocation((agentId: agentId, groupId: ''));
    } else if (agentId.isEmpty) {
      _applyConversationListLocation((agentId: '', groupId: ''));
    }
  }

  void _showAgentConversationList(String agentId) {
    final next = (agentId: agentId, groupId: '');
    if (_conversationListLocation == next) return;
    setState(() {
      _showAgentDetailInsideGroupList = false;
      _conversationListHistory.add(_conversationListLocation);
      _applyConversationListLocation(next);
    });
  }

  void _showGroupConversationList(String conversationId) {
    final next = (agentId: '', groupId: conversationId);
    if (_conversationListLocation == next) return;
    setState(() {
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
      unawaited(
        widget.controller.clientConversationController.selectConversation(
          groupId,
        ),
      );
      return;
    }
    final previous = _conversationListHistory.isEmpty
        ? (agentId: '', groupId: '')
        : _conversationListHistory.removeLast();
    setState(() {
      _showAgentDetailInsideGroupList = false;
      _applyConversationListLocation(previous);
    });

    final controller = widget.controller;
    if (previous.groupId.isNotEmpty) {
      unawaited(
        controller.clientConversationController.selectConversation(
          previous.groupId,
        ),
      );
    } else if (previous.agentId.isNotEmpty) {
      controller.clientConversationController.clearSelection();
      unawaited(controller.selectConversationAgent(previous.agentId));
    }
  }

  void _showWelcome(ClientController controller) {
    setState(() {
      _showAgentDetailInsideGroupList = false;
      _conversationListHistory.clear();
      _applyConversationListLocation((agentId: '', groupId: ''));
    });
    controller.showConversationWelcomePage();
  }

  bool _isConversationSessionRunning(
    ClientController controller,
    AgentConversationSession session,
  ) {
    if (session.running) return true;
    if (!controller.isSendingConversationMessage) return false;
    final nativeSessionId = session.nativeSessionId.trim();
    final selectedSessionId = controller.selectedConversationSession?.id ?? '';
    return (controller.sendingConversationSessionId.isNotEmpty &&
            session.id == controller.sendingConversationSessionId) ||
        (controller.sendingConversationNativeSessionId.isNotEmpty &&
            nativeSessionId == controller.sendingConversationNativeSessionId) ||
        (controller.sendingConversationSessionId.isEmpty &&
            controller.sendingConversationNativeSessionId.isEmpty &&
            session.id == selectedSessionId);
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

  Future<void> _pickConversationAttachments(ClientController controller) async {
    await _pickConversationAttachmentsForScope(
      controller,
      controller.conversationComposerScopeKey,
    );
  }

  /// Composer scope key for the selected canonical group conversation, beside
  /// the per-agent session scopes. Empty while no group is selected.
  String _groupComposerScopeKey(ClientController controller) {
    final conversationId = controller
        .clientConversationController
        .selectedConversationId
        .trim();
    return conversationId.isEmpty ? '' : 'group:$conversationId';
  }

  bool _scopeKeyIsCurrent(ClientController controller, String scopeKey) {
    return scopeKey == controller.conversationComposerScopeKey ||
        scopeKey == _groupComposerScopeKey(controller);
  }

  void _replaceScopeAttachments(
    ClientController controller,
    String scopeKey,
    List<ConversationAttachment> attachments, {
    String statusCode = '',
  }) {
    if (scopeKey == controller.conversationComposerScopeKey) {
      controller.replaceConversationComposerAttachments(
        attachments,
        statusCode: statusCode,
      );
      return;
    }
    final signals = controller.conversationPresentationSignals;
    signals.replaceComposerAttachments(scopeKey, attachments);
    signals.replaceComposerAttachmentStatus(scopeKey, statusCode);
    controller.agentWorkspaceNotifyStateChanged();
  }

  Future<void> _pickConversationAttachmentsForScope(
    ClientController controller,
    String scopeKey,
  ) async {
    if (scopeKey.trim().isEmpty || _pickingConversationAttachments) return;
    _pickingConversationAttachments = true;
    bool scopeIsCurrent() =>
        mounted &&
        identical(controller, widget.controller) &&
        _scopeKeyIsCurrent(controller, scopeKey);
    try {
      const imageTypes = XTypeGroup(
        label: 'Images',
        extensions: ['png', 'jpg', 'jpeg', 'gif', 'webp'],
      );
      final List<XFile> picked;
      try {
        picked = await openFiles(acceptedTypeGroups: [imageTypes]);
      } on Object {
        if (scopeIsCurrent()) {
          _replaceScopeAttachments(
            controller,
            scopeKey,
            _attachmentsForScope(controller, scopeKey),
            statusCode: conversationAttachmentStatusFailed,
          );
        }
        return;
      }
      if (!scopeIsCurrent()) return;
      final current = _attachmentsForScope(controller, scopeKey);
      if (picked.isEmpty) {
        _replaceScopeAttachments(
          controller,
          scopeKey,
          current,
          statusCode: conversationAttachmentStatusCancelled,
        );
        return;
      }
      final sequence = DateTime.now().toUtc().microsecondsSinceEpoch;
      final additions = <ConversationAttachment>[];
      for (var index = 0; index < picked.length; index += 1) {
        final file = picked[index];
        final mediaType = conversationAttachmentMediaTypeForExtension(
          p.extension(file.name).replaceFirst('.', ''),
        );
        if (mediaType.isEmpty) {
          _replaceScopeAttachments(
            controller,
            scopeKey,
            current,
            statusCode: conversationAttachmentFailureMediaUnsupported,
          );
          return;
        }
        additions.add(
          ConversationAttachment(
            id: 'selection-$sequence-$index',
            name: file.name,
            mediaType: mediaType,
            path: file.path,
          ),
        );
      }
      await _appendConversationAttachments(
        controller: controller,
        scopeKey: scopeKey,
        scopeIsCurrent: scopeIsCurrent,
        current: current,
        additions: additions,
      );
    } finally {
      _pickingConversationAttachments = false;
    }
  }

  List<ConversationAttachment> _attachmentsForScope(
    ClientController controller,
    String scopeKey,
  ) => controller.conversationPresentationSignals.composerAttachmentsFor(
    scopeKey,
  );

  Future<bool> _pasteConversationImage(ClientController controller) async {
    if (_pickingConversationAttachments) return true;
    _pickingConversationAttachments = true;
    final scopeKey = controller.conversationComposerScopeKey;
    bool scopeIsCurrent() =>
        mounted &&
        identical(controller, widget.controller) &&
        controller.conversationComposerScopeKey == scopeKey;
    try {
      final current = controller.conversationComposerAttachments;
      if (current.length >= maxConversationImageAttachments) {
        controller.replaceConversationComposerAttachments(
          current,
          statusCode: conversationAttachmentStatusLimit,
        );
        return true;
      }
      final result = await controller.clientClipboardService
          .readImageAttachment();
      if (!result.consumed) return false;
      final attachment = result.attachment;
      if (!scopeIsCurrent()) {
        if (attachment != null) {
          await controller.conversationAttachmentRelease.releaseAttachments([
            attachment,
          ]);
        }
        return true;
      }
      if (!result.succeeded || attachment == null) {
        controller.replaceConversationComposerAttachments(
          current,
          statusCode: result.failureCode,
        );
        return true;
      }
      await _appendConversationAttachments(
        controller: controller,
        scopeKey: scopeKey,
        scopeIsCurrent: scopeIsCurrent,
        current: current,
        additions: [attachment],
      );
      return true;
    } finally {
      _pickingConversationAttachments = false;
    }
  }

  Future<bool> _appendConversationAttachments({
    required ClientController controller,
    required String scopeKey,
    required bool Function() scopeIsCurrent,
    required List<ConversationAttachment> current,
    required List<ConversationAttachment> additions,
  }) async {
    Future<bool> reject(String statusCode) async {
      await controller.conversationAttachmentRelease.releaseAttachments(
        additions,
      );
      if (scopeIsCurrent()) {
        _replaceScopeAttachments(
          controller,
          scopeKey,
          current,
          statusCode: statusCode,
        );
      }
      return false;
    }

    if (current.length + additions.length > maxConversationImageAttachments) {
      return reject(conversationAttachmentStatusLimit);
    }
    var totalBytes = 0;
    for (final attachment in [...current, ...additions]) {
      final read = await controller.conversationImageByteReader.read(
        localPath: attachment.path,
        mediaType: attachment.mediaType,
      );
      if (!scopeIsCurrent()) {
        await controller.conversationAttachmentRelease.releaseAttachments(
          additions,
        );
        return false;
      }
      if (!read.succeeded) return reject(read.failureCode);
      totalBytes += read.bytes!.length;
      if (totalBytes > maxConversationImageBytesTotal) {
        return reject(conversationAttachmentFailureSizeLimit);
      }
    }
    _replaceScopeAttachments(controller, scopeKey, [...current, ...additions]);
    return true;
  }

  /// Stages picked images into the selected group's composer scope.
  Future<void> _pickGroupComposerImages(ClientController controller) async {
    await _pickConversationAttachmentsForScope(
      controller,
      _groupComposerScopeKey(controller),
    );
  }

  /// Abandons the selected group's staged images: the scope clear also
  /// releases the picked files.
  void _clearGroupComposerImages(ClientController controller) {
    final scopeKey = _groupComposerScopeKey(controller);
    if (scopeKey.isEmpty) return;
    controller.clearConversationComposerAttachmentsForScope(scopeKey);
  }

  /// Whether the selected group's assistant agent target transports images
  /// end to end: the packaged `multimodal` capability truth intersected with
  /// desktop, direct-local, non-VM transport, same as the 1:1 predicate.
  bool _groupAssistantSupportsImageAttachments(ClientController controller) {
    if (controller.mobileClientRuntimePlatform) return false;
    final conversation =
        controller.clientConversationController.selectedConversation;
    final agentId =
        conversation?.assistantMembership?.principal.agentId.trim() ?? '';
    if (agentId.isEmpty) return false;
    for (final target in widget.targets) {
      if (target.target != agentId && target.id != agentId) continue;
      if (target.conversationCapabilityMatrix['multimodal'] != true) {
        return false;
      }
      return target.location == 'local' &&
          !target.hasValidVirtualMachineConnection;
    }
    return false;
  }

  /// The canonical group pane with its composer attachment scope wired to the
  /// shared presentation-signals store (`group:<conversationId>`) and the
  /// platform image byte reader scoped above it.
  Widget _canonicalGroupPane(
    ClientController controller,
    ClientConversationController groupController, {
    bool framed = true,
    ValueChanged<String>? onOpenAgentConversations,
  }) {
    final scopeKey = _groupComposerScopeKey(controller);
    final signals = controller.conversationPresentationSignals;
    return ConversationImageByteReaderScope(
      reader: controller.conversationImageByteReader,
      child: CanonicalGroupConversationPane(
        controller: groupController,
        targets: widget.targets,
        onCopyText: controller.clientClipboardService.writeText,
        onOpenAgentConversations: onOpenAgentConversations,
        framed: framed,
        flywheelGateway: controller.adaptiveFlywheelGateway,
        persistentGateway:
            controller.conversationGateway is PersistentAgentConversationGateway
            ? controller.conversationGateway
                  as PersistentAgentConversationGateway
            : null,
        onOpenAdaptiveFlywheel: (revision) => showAdaptiveFlywheelDialog(
          context,
          controller,
          initialRevision: revision ?? '',
        ),
        composerAttachments: scopeKey.isEmpty
            ? const <ConversationAttachment>[]
            : signals.composerAttachmentsFor(scopeKey),
        onPickComposerImages: () =>
            unawaited(_pickGroupComposerImages(controller)),
        onClearComposerImages: () => _clearGroupComposerImages(controller),
        assistantSupportsImageAttachments:
            _groupAssistantSupportsImageAttachments(controller),
        providerQuotaController: controller.providerQuotaController,
      ),
    );
  }

  Widget _activeConversationPane({
    required ClientController controller,
    required TargetCandidate target,
    required LicoStrings strings,
    bool framed = true,
    bool showSidebarToggle = true,
  }) {
    final strategy = LayoutAgentsStrategyScope.maybeOf(context);
    final showWorkingDirectory =
        !controller.mobileClientRuntimePlatform &&
        !target.hasValidVirtualMachineConnection;
    final workingDirectorySelectable =
        showWorkingDirectory &&
        controller.canSelectNewConversationWorkingDirectory;
    final projection = controller.conversationProjectionFor(
      controller.conversationComposerScopeKey,
    );
    final projectedInputEnabled = projection.turnState.inputEnabled;
    final composerEnabled =
        target.canRelayRuntime && (projectedInputEnabled ?? true);
    final projectedMessages = projection.messages;
    final attachmentStatus = controller.conversationAttachmentStatus;
    final gateReasonCode = composerEnabled
        ? (attachmentStatus.isNotEmpty
              ? attachmentStatus
              : controller.conversationSendErrorFor(target.target))
        : target.conversationSendGateReason;
    final session = controller.selectedConversationSession;
    final opencodeServeState = controller.opencodeServeState;
    final opencodeServeStatus =
        switch ((opencodeServeState?['status'] as String?)?.trim()) {
          'running' => AgentConversationServeStatus.running,
          'blocked' => AgentConversationServeStatus.blocked,
          'unavailable' => AgentConversationServeStatus.unavailable,
          _ => AgentConversationServeStatus.stopped,
        };
    final primaryConversationId = session == null
        ? ''
        : messagingDetailsConversationId(session);
    final participantConversationIds = <String, String>{};
    final agentId = target.target.trim();
    if (agentId.isNotEmpty && primaryConversationId.isNotEmpty) {
      participantConversationIds[agentId] = primaryConversationId;
    }
    final state = AgentConversationPaneState(
      target: target,
      session: session,
      liveMessages:
          projectedMessages.isEmpty ||
              controller.conversationComposerAttachments.isNotEmpty
          ? controller.selectedConversationTimelineMessages
          : projectedMessages,
      recentSessions: controller.selectedConversationSessions,
      loading: controller.isLoadingConversations,
      recentSessionsHasMore: controller.selectedConversationSessionsHasMore,
      recentSessionsLoadingMore:
          controller.isLoadingMoreSelectedConversationSessions,
      messagePageLoading:
          controller.isLoadingEarlierSelectedConversationMessages,
      messagePageError: controller.selectedConversationMessagePageError,
      turnActive: projection.turnState.active,
      inputEnabled: composerEnabled,
      cancelEnabled: projection.turnState.cancelEnabled ?? false,
      preparingNewConversation: controller.preparingNewConversation,
      composerEnabled: composerEnabled,
      sendGateReasonCode: gateReasonCode,
      composerDraft: controller.conversationComposerDraft,
      hasAttachments: controller.conversationComposerAttachments.isNotEmpty,
      modelOptions: controller.selectedConversationModelOptions,
      selectedModel: controller.selectedConversationModel,
      defaultModel: controller.selectedConversationDefaultModel,
      reasoningEffortOptions:
          controller.selectedConversationReasoningEffortOptions,
      selectedReasoningEffort: controller.selectedConversationReasoningEffort,
      defaultReasoningEffort:
          controller.selectedConversationDefaultReasoningEffort,
      showWorkingDirectory: showWorkingDirectory,
      workingDirectory: showWorkingDirectory
          ? controller.selectedConversationWorkingDirectory
          : '',
      workingDirectorySelectable: workingDirectorySelectable,
      sendAuthorizeActive: controller.isAuthorizingConversationRuntime,
      permissionRetryTool: controller.pendingPermissionRetryTool,
      participantTargets: controller.scannedTargets,
      showLicoProfileCapsule:
          controller.selectedConversationSupportsLicoProfile,
      selectedLicoProfile: controller.selectedConversationLicoProfile,
      planDocumentPath: _planDocumentPath(controller),
      planDocumentReader: controller.planDocumentReader,
      participantConversationIds: participantConversationIds,
      runningRecentSessionIds: {
        for (final recentSession in controller.selectedConversationSessions)
          if (_isConversationSessionRunning(controller, recentSession))
            recentSession.id,
      },
      recentSessionsCached: controller.selectedConversationSessions.isNotEmpty,
    );
    final onUnblockSend = switch (gateReasonCode) {
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
      onCopyText: controller.clientClipboardService.writeText,
      onSend: controller.sendConversationMessage,
      onCancel: controller.cancelActiveConversationTurn,
      onSelectSession: (sessionId) {
        _showAgentConversationList(target.target);
        controller.selectConversationSession(sessionId);
      },
      onNewConversation: controller.startNewConversationSession,
      onLoadMoreRecentSessions: () =>
          unawaited(controller.loadMoreConversationSessions(target.target)),
      onLoadEarlierMessages: controller.loadEarlierConversationMessages,
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
              controller.selectedConversationSupportsImageAttachments
          ? () => unawaited(_pickConversationAttachments(controller))
          : null,
      onPasteImage:
          strategy.messageStyle == AgentsMessageStyle.participantFlow &&
              controller.selectedConversationSupportsImageAttachments
          ? () => _pasteConversationImage(controller)
          : null,
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
    final messaging =
        strategy.messageStyle == AgentsMessageStyle.participantFlow;
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
              switcherRunningFor: (candidate) =>
                  _isConversationSessionRunning(controller, candidate),
            )
          : ConversationPaneHeader(
              state: headerState,
              actions: AgentConversationHeaderActions(
                onToggleHistory: _toggleHistoryCollapsed,
              ),
              strategy: strategy,
            ),
      framed: framed,
    );
    final pendingApprovals = controller.secureMeshApprovalInbox
        .where((item) => item.isPending)
        .toList(growable: false);
    final content = pendingApprovals.isEmpty
        ? pane
        : Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
                child: SecureMeshApprovalCard(controller: controller),
              ),
              Expanded(child: pane),
            ],
          );
    return ConversationImageByteReaderScope(
      reader: controller.conversationImageByteReader,
      child: content,
    );
  }

  Widget _detailForSelection({
    required bool hasSelection,
    required Widget conversationPane,
  }) {
    TargetCandidate? firstConversationTarget;
    for (final target in widget.targets) {
      if (target.isConversationAgent) {
        firstConversationTarget = target;
        break;
      }
    }
    return !hasSelection
        ? AgentConversationWelcome(
            onNewConversation: firstConversationTarget == null
                ? null
                : () => unawaited(
                    widget.controller.selectConversationAgent(
                      firstConversationTarget!.id,
                    ),
                  ),
            onNewGroupConversation: () => unawaited(
              showCreateCanonicalGroupConversationDialog(
                context: context,
                controller: widget.controller.clientConversationController,
                targets: widget.targets,
              ),
            ),
            onOpenMobilePairing: () =>
                widget.controller.selectSection(ClientSection.mobileRelay),
            onOpenSettings: () =>
                widget.controller.selectSection(ClientSection.settings),
          )
        : conversationPane;
  }

  Widget _buildFloatingShell({
    required ClientController controller,
    required TargetCandidate? target,
    required bool groupSelected,
    required Widget conversationPane,
    required VoidCallback onAddTarget,
    required bool allowManualTargetActions,
    required LayoutAgentsPresentation presentation,
  }) {
    var showConversationList = false;
    var conversationListTargets = const <TargetCandidate>[];
    Set<String>? conversationListRelatedAgentIds;
    var conversationListPriorityAgentId = '';
    var showConversationAgentIcons = false;
    if (_conversationListGroupId.isNotEmpty) {
      showConversationList = true;
      final selectedGroup =
          controller.clientConversationController.selectedConversation;
      if (selectedGroup?.id == _conversationListGroupId) {
        final memberProductIds = {
          for (final membership in selectedGroup!.memberships)
            if (membership.principal.agentId.trim().isNotEmpty)
              agentConversationProductId(membership.principal.agentId.trim()),
        };
        conversationListTargets = widget.targets
            .where((target) => target.isConversationAgent)
            .toList(growable: false);
        conversationListRelatedAgentIds = <String>{};
        for (final target in conversationListTargets) {
          if (memberProductIds.contains(
            agentConversationProductId(target.target),
          )) {
            conversationListRelatedAgentIds
              ..add(target.id)
              ..add(target.target);
          }
        }
        // The group's assistant thread pins to the top of the drill-in list
        // by default.
        conversationListPriorityAgentId =
            selectedGroup.assistantMembership?.principal.agentId.trim() ?? '';
      }
      showConversationAgentIcons = true;
    } else if (_conversationListAgentId.isNotEmpty) {
      TargetCandidate? representative;
      for (final candidate in widget.targets) {
        if (candidate.id == _conversationListAgentId ||
            candidate.target == _conversationListAgentId) {
          representative = candidate;
          break;
        }
      }
      if (representative != null) {
        showConversationList = true;
        final productId = agentConversationProductId(representative.target);
        conversationListTargets = widget.targets
            .where(
              (candidate) =>
                  candidate.isConversationAgent &&
                  agentConversationProductId(candidate.target) == productId,
            )
            .toList(growable: false);
      }
    }
    return ColoredBox(
      key: const Key('agents-workspace-shell'),
      color: presentation.canvasColor(context.layoutPalette),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Never let the upper bound fall below the minimum: a window
          // narrower than the sidebar minimum would otherwise feed a
          // lower-than-lower clamp and crash the build.
          final maxSidebarWidth = math
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
          final sidebarWidth = _sidebarWidth
              .clamp(agentsSidebarMinWidth, maxSidebarWidth)
              .toDouble();
          final strategy = LayoutAgentsStrategyScope.maybeOf(context);
          final agentTreeSidebar = AgentsWorkspaceSidebar(
            targets: widget.targets,
            sessionsByAgent: controller.conversationSessionsByAgent,
            selectedSessionId: controller.selectedConversationSession?.id ?? '',
            activityFor: controller.conversationTabActivityFor,
            runningFor: (session) =>
                _isConversationSessionRunning(controller, session),
            onSelectSession: (agentId, sessionId) async {
              controller.clientConversationController.clearSelection();
              await controller.selectConversationAgent(agentId);
              controller.selectConversationSession(sessionId);
            },
            onNewConversation: () {
              controller.clientConversationController.clearSelection();
              controller.startNewConversationSession();
            },
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
          final canonicalGroupSidebar = CanonicalGroupConversationSidebar(
            conversations:
                controller.clientConversationController.groupConversations,
            selectedConversationId:
                controller.clientConversationController.selectedConversationId,
            onSelect: (conversationId) => unawaited(
              controller.clientConversationController.selectConversation(
                conversationId,
              ),
            ),
            onCreate: () => unawaited(
              showCreateCanonicalGroupConversationDialog(
                context: context,
                controller: controller.clientConversationController,
                targets: widget.targets,
              ),
            ),
          );
          final sidebar = switch (strategy.sidebarStyle) {
            AgentsSidebarStyle.agentTree => Column(
              children: [
                canonicalGroupSidebar,
                Expanded(child: agentTreeSidebar),
              ],
            ),
            AgentsSidebarStyle.flatRecencyList => MessagingContactList(
              targets: widget.targets,
              sessionsByAgent: controller.conversationSessionsByAgent,
              selectedAgentId: controller.selectedConversationAgentId,
              groupConversations:
                  controller.clientConversationController.groupConversations,
              selectedGroupConversationId: controller
                  .clientConversationController
                  .selectedConversationId,
              onSelectGroupConversation: (conversationId) {
                _showAgentDetailInsideGroupList = false;
                _showGroupConversationList(conversationId);
                unawaited(
                  controller.clientConversationController.selectConversation(
                    conversationId,
                  ),
                );
              },
              onSetGroupConversationPinned: (conversationId, pinned) =>
                  unawaited(
                    controller.clientConversationController.setPinned(
                      conversationId,
                      pinned,
                    ),
                  ),
              onArchiveGroupConversation: (conversationId) {
                if (controller
                        .clientConversationController
                        .selectedConversationId ==
                    conversationId) {
                  setState(() {
                    _showAgentDetailInsideGroupList = false;
                    _conversationListHistory.clear();
                    _applyConversationListLocation((agentId: '', groupId: ''));
                  });
                }
                unawaited(
                  controller.clientConversationController.archiveConversation(
                    conversationId,
                  ),
                );
              },
              onNewGroupConversation: () => unawaited(
                showCreateCanonicalGroupConversationDialog(
                  context: context,
                  controller: controller.clientConversationController,
                  targets: widget.targets,
                ),
              ),
              activityFor: controller.conversationTabActivityFor,
              runningFor: (session) =>
                  _isConversationSessionRunning(controller, session),
              onSelectAgent: (agentId) {
                unawaited(() async {
                  controller.clientConversationController.clearSelection();
                  if (agentId == controller.selectedConversationAgentId) {
                    // Tapping the active contact returns to its
                    // new-conversation home.
                    controller.startNewConversationSession();
                    return;
                  }
                  await controller.selectConversationAgent(agentId);
                }());
              },
              onNewConversation: () {
                controller.clientConversationController.clearSelection();
                controller.startNewConversationSession();
              },
              onSearch: widget.onSearch,
              onOpenWelcome: () => _showWelcome(controller),
              showConversationList: showConversationList,
              conversationListTargets: conversationListTargets,
              conversationListRelatedAgentIds: conversationListRelatedAgentIds,
              priorityAgentId: conversationListPriorityAgentId,
              selectedSessionId:
                  controller.selectedConversationSession?.id ?? '',
              showConversationAgentIcons: showConversationAgentIcons,
              onSelectSession: (agentId, sessionId) => unawaited(() async {
                if (_conversationListGroupId.isNotEmpty) {
                  final groupListId = _conversationListGroupId;
                  final selection = controller.selectConversationAgent(agentId);
                  setState(() {
                    _showAgentDetailInsideGroupList = true;
                  });
                  await selection;
                  if (!mounted || _conversationListGroupId != groupListId) {
                    return;
                  }
                  controller.selectConversationSession(sessionId);
                  return;
                }
                controller.clientConversationController.clearSelection();
                await controller.selectConversationAgent(agentId);
                controller.selectConversationSession(sessionId);
              }()),
              onBack: _returnToPreviousConversationList,
              onPrefetchSessions: (agentId) =>
                  unawaited(controller.refreshConversationSessions(agentId)),
              isPinned: controller.isConversationTargetPinned,
              onTogglePinned: (agentId) =>
                  unawaited(controller.toggleConversationTargetPinned(agentId)),
              scanning: widget.scanning,
              loading: controller.isLoadingConversations,
              activeDestination: controller.currentSection,
              onSelectDestination: controller.selectSection,
            ),
          };
          final detail = _detailForSelection(
            hasSelection: groupSelected || target != null,
            conversationPane: conversationPane,
          );
          final sidebarPane = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [Expanded(child: sidebar)],
          );
          void resizeSidebar(double delta) {
            setState(() {
              _sidebarWidth = (sidebarWidth + delta)
                  .clamp(agentsSidebarMinWidth, maxSidebarWidth)
                  .toDouble();
            });
            _writeLayoutState(
              LayoutStateChannels.agentsSidebar,
              LayoutPaneExtentState(_sidebarWidth),
            );
          }

          final framedDetail = presentation.frameDetail(
            context,
            key: const Key('agents-workspace-detail-pane'),
            sidebarCollapsed: _historyCollapsed,
            child: detail,
          );
          final hostedSplit =
              MessagingSidebarGeometryScope.maybeOf(context) != null;
          return presentation.frameWorkspace(
            context,
            key: const Key('agents-workspace-layout'),
            child: hostedSplit
                ? MessagingSidebarColumn(
                    sidebar: sidebarPane,
                    detail: framedDetail,
                    sidebarCollapsed: _historyCollapsed,
                  )
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (!_historyCollapsed)
                        presentation.frameSidebar(
                          context,
                          key: const Key('agents-workspace-sidebar-card'),
                          child: SizedBox(
                            width: sidebarWidth,
                            child: sidebarPane,
                          ),
                        ),
                      Expanded(
                        child: PaneEdgeDragHandle(
                          dragHandleKey: const Key(
                            'agents-workspace-split-divider',
                          ),
                          width: agentsSidebarDividerWidth,
                          enabled: !_historyCollapsed,
                          onDragDelta: resizeSidebar,
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

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    _syncConversationListWithSelection(controller);
    final onAddTarget = widget.onAddTarget;
    final allowManualTargetActions = widget.allowManualTargetActions;
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final target = controller.selectedConversationAgent;
    final groupController = controller.clientConversationController;
    final groupSelected = groupController.selectedConversationId.isNotEmpty;
    final mobileClient = isMobileClientPlatform(context);

    if (widget.useFloatingShell && !mobileClient) {
      final presentation = LayoutDestinationPresentationScope.agentsOf(context);
      final showGroupPane = groupSelected && !_showAgentDetailInsideGroupList;
      final conversationPane = showGroupPane
          ? _canonicalGroupPane(
              controller,
              groupController,
              framed: false,
              onOpenAgentConversations: (agentId) {
                _showAgentConversationList(agentId);
                groupController.clearSelection();
                unawaited(controller.selectConversationAgent(agentId));
              },
            )
          : target == null
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
        groupSelected: groupSelected,
        conversationPane: conversationPane,
        onAddTarget: onAddTarget,
        allowManualTargetActions: allowManualTargetActions,
        presentation: presentation,
      );
    }

    if (groupSelected) {
      final groupPane = _canonicalGroupPane(controller, groupController);
      final groupPendingApprovals = controller.secureMeshApprovalInbox
          .where((item) => item.isPending)
          .toList(growable: false);
      if (groupPendingApprovals.isEmpty) {
        return groupPane;
      }
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
            child: SecureMeshApprovalCard(controller: controller),
          ),
          Expanded(child: groupPane),
        ],
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
              session.running ||
              (controller.isSendingConversationMessage &&
                  ((controller.sendingConversationSessionId.isNotEmpty &&
                          session.id ==
                              controller.sendingConversationSessionId) ||
                      (controller
                              .sendingConversationNativeSessionId
                              .isNotEmpty &&
                          nativeId ==
                              controller.sendingConversationNativeSessionId) ||
                      (controller.sendingConversationSessionId.isEmpty &&
                          controller
                              .sendingConversationNativeSessionId
                              .isEmpty &&
                          session.id == selectedSessionId)));
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
