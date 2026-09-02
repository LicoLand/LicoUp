import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_composer.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_composer_capsules.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_display_names.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_message_view.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_pane_controls.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_pane_presentation.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_parity_disclosure.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_recent_sessions.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_virtual_machine_destination.dart';
import 'package:licoup/src/frontend/features/agents/ui/lico_plan_document_panel.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_agents_strategy.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/tokens/messaging_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/platform/client_platform.dart';
import 'package:licoup/src/frontend/shared/ui/lico_activity_animations.dart';
import 'package:licoup/src/frontend/shared/ui/panel_frame.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

/// Composes an already projected conversation view. Controller listening and
/// domain-to-presentation adaptation belong exclusively to the workspace.
class AgentConversationActivePane extends StatelessWidget {
  const AgentConversationActivePane({
    super.key,
    required this.state,
    required this.actions,
    required this.header,
    this.framed = true,
    this.messageScrollController,
  });

  final AgentConversationPaneState state;
  final AgentConversationPaneActions actions;
  final Widget header;
  final bool framed;
  final ScrollController? messageScrollController;

  @override
  Widget build(BuildContext context) {
    final mobileClient = isMobileClientPlatform(context);
    final strings = LicoStrings.of(context);
    final strategy = LayoutAgentsStrategyScope.maybeOf(context);
    final unavailableCopy = conversationSendAvailabilityCopy(
      strings: strings,
      reasonCode: state.sendGateReasonCode,
    );
    final messagingFlow =
        strategy.messageStyle == AgentsMessageStyle.participantFlow;
    final composer = RuntimeMessageComposer(
      targetLabel: state.conversationLabel.trim().isNotEmpty
          ? state.conversationLabel.trim()
          : agentConversationTargetDisplayName(state.target),
      initialDraft: state.composerDraft,
      hasAttachments: state.hasAttachments,
      busy: state.composerBusy,
      enabled: state.composerEnabled && state.inputEnabled,
      cancelEnabled: state.cancelEnabled,
      modelOptions: state.modelOptions,
      selectedModel: state.selectedModel,
      reasoningEffortOptions: state.reasoningEffortOptions,
      selectedReasoningEffort: state.selectedReasoningEffort,
      onModelChanged: actions.onModelChanged,
      onReasoningEffortChanged: actions.onReasoningEffortChanged,
      onDraftChanged: actions.onDraftChanged,
      onSend: actions.onSend,
      onSlashNewConversation: actions.onNewConversation,
      onCancel: actions.onCancel,
      defaultModel: state.defaultModel,
      defaultReasoningEffort: state.defaultReasoningEffort,
      showRuntimeSettings:
          strategy.composerStyle == AgentsComposerStyle.withRuntimeBar,
      showWorkingDirectory: state.showWorkingDirectory,
      workingDirectory: state.workingDirectory,
      workingDirectorySelectable: state.workingDirectorySelectable,
      onChooseWorkingDirectory: actions.onChooseWorkingDirectory,
      floatingMatteCapsule: !mobileClient && messagingFlow,
      onAttach: actions.onAttach,
      onPasteImage: actions.onPasteImage,
      mentionTargets: state.participantTargets
          .where(
            (target) => state.composerMentionLabels.containsKey(target.target),
          )
          .toList(growable: false),
      mentionLabels: state.composerMentionLabels,
      leading: state.composerLeading,
      fieldLeading: state.composerFieldLeading,
    );
    final sendUnavailable = state.composerEnabled
        ? null
        : _ConversationSendUnavailableRow(
            copy: unavailableCopy,
            onUnblock: unavailableCopy.unblockAction == null
                ? null
                : actions.onUnblockSend,
          );
    final sendFailure =
        state.composerEnabled &&
            !state.turnActive &&
            state.sendGateReasonCode.trim().isNotEmpty
        ? _ConversationSendFailureRow(
            message: strings.conversationSendFailed(
              unavailableCopy.reasonLabel,
            ),
            actionLabel:
                unavailableCopy.unblockAction ==
                    ConversationSendUnblockAction.authorizeRuntime
                ? (state.sendAuthorizeActive
                      ? strings.conversationAuthorizingRuntimeAction
                      : unavailableCopy.unblockLabel)
                : null,
            onAction:
                unavailableCopy.unblockAction ==
                        ConversationSendUnblockAction.authorizeRuntime &&
                    !state.sendAuthorizeActive
                ? actions.onUnblockSend
                : null,
          )
        : null;
    final permissionRetry =
        state.permissionRetryTool.trim().isNotEmpty && !state.turnActive
        ? _ConversationPermissionRetryRow(
            tool: state.permissionRetryTool,
            onAllow: actions.onPermissionRetry,
            onAllowAndRemember: actions.onPermissionRetryRemember,
            onDeny: actions.onPermissionDeny,
          )
        : null;
    final licoProfileCapsule = state.showLicoProfileCapsule
        ? ComposerLicoProfileCapsule(
            selectedProfile: state.selectedLicoProfile,
            onChanged: actions.onLicoProfileChanged ?? (_) {},
          )
        : null;
    final showComposerCapsuleRow =
        (messagingFlow &&
            ((state.showWorkingDirectory &&
                    state.workingDirectory.trim().isNotEmpty) ||
                state.modelOptions.isNotEmpty ||
                state.reasoningEffortOptions.isNotEmpty ||
                licoProfileCapsule != null)) ||
        state.composerFlywheel != null;
    final headerOverlayInset = !mobileClient && messagingFlow
        ? MessagingDesktopMetrics.conversationHeaderOverlayExtent
        : 0.0;
    final composerOverlayInset = !mobileClient && messagingFlow
        ? MessagingDesktopMetrics.conversationComposerOverlayExtent +
              (showComposerCapsuleRow
                  ? MessagingDesktopMetrics.conversationComposerCapsuleRowExtent
                  : 0)
        : 0.0;
    final messageSurface =
        state.session == null &&
            state.preparingNewConversation &&
            state.liveMessages.isEmpty
        ? AgentConversationRecentSessions(
            sessions: state.recentSessions,
            runningSessionIds: state.runningRecentSessionIds,
            loading: state.loading && !state.recentSessionsCached,
            hasMore: state.recentSessionsHasMore,
            loadingMore: state.recentSessionsLoadingMore,
            onNewConversation: actions.onNewConversation ?? () {},
            onSelectSession: actions.onSelectSession,
            onLoadMore: actions.onLoadMoreRecentSessions,
            topOverlayInset: headerOverlayInset,
            bottomOverlayInset: composerOverlayInset,
          )
        : AgentConversationMessageList(
            scrollController: messageScrollController,
            loading: state.loading,
            messagePageLoading: state.messagePageLoading,
            messagePageError: state.messagePageError,
            onLoadEarlier: actions.onLoadEarlierMessages,
            session: state.session,
            target: state.target,
            turnActive: state.turnActive,
            liveMessages: state.liveMessages,
            messageStyle: strategy.messageStyle,
            processStyle: strategy.processStyle,
            participantTargets: state.participantTargets,
            participantConversationIds: state.participantConversationIds,
            participantRuntimeProfiles: state.participantRuntimeProfiles,
            topOverlayInset: headerOverlayInset,
            bottomOverlayInset: composerOverlayInset,
            onCopyText: actions.onCopyText,
          );
    final messages = RepaintBoundary(
      key: const Key('conversation-streaming-repaint-boundary'),
      child: messageSurface,
    );
    final showPlanDocumentPanel =
        !mobileClient &&
        messagingFlow &&
        state.selectedLicoProfile == 'plan' &&
        state.planDocumentPath.trim().isNotEmpty;
    final messagingHeader = header;
    if (mobileClient) {
      return Column(
        children: [
          // Console mobile surfaces the parity and VM chips above the
          // transcript; messaging keeps them inside the details sheet.
          if (!messagingFlow)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    ConversationParityDisclosurePanel(
                      target: state.target,
                      compact: true,
                    ),
                    if (state.target.hasValidVirtualMachineConnection)
                      ConversationVirtualMachineDestinationChip(
                        destination: state.target.virtualMachineDestination,
                      ),
                  ],
                ),
              ),
            ),
          Expanded(child: messages),
          ?sendUnavailable,
          ?sendFailure,
          ?permissionRetry,
          if (showComposerCapsuleRow)
            ComposerCapsuleRow(
              modelOptions: state.modelOptions,
              selectedModel: state.selectedModel,
              defaultModel: state.defaultModel,
              modelSelectionEnabled: state.composerEnabled,
              onModelChanged: actions.onModelChanged,
              reasoningEffortOptions: state.reasoningEffortOptions,
              selectedReasoningEffort: state.selectedReasoningEffort,
              defaultReasoningEffort: state.defaultReasoningEffort,
              onReasoningEffortChanged: actions.onReasoningEffortChanged,
              licoProfileCapsule: licoProfileCapsule,
              flywheel: state.composerFlywheel,
            ),
          MobileComposerSurface(child: composer),
        ],
      );
    }
    final colors = context.licoColors;
    // Messaging: header + matte composer overlay the full-height transcript.
    // Console keeps the classic band + running-edge divider.
    final bottomDock = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ?sendUnavailable,
        ?sendFailure,
        ?permissionRetry,
        if (showComposerCapsuleRow)
          ComposerCapsuleRow(
            workingDirectory: state.showWorkingDirectory
                ? state.workingDirectory
                : null,
            workingDirectorySelectable: state.workingDirectorySelectable,
            onChooseWorkingDirectory: actions.onChooseWorkingDirectory,
            modelOptions: state.modelOptions,
            selectedModel: state.selectedModel,
            defaultModel: state.defaultModel,
            modelSelectionEnabled: state.composerEnabled,
            onModelChanged: actions.onModelChanged,
            reasoningEffortOptions: state.reasoningEffortOptions,
            selectedReasoningEffort: state.selectedReasoningEffort,
            defaultReasoningEffort: state.defaultReasoningEffort,
            onReasoningEffortChanged: actions.onReasoningEffortChanged,
            licoProfileCapsule: licoProfileCapsule,
            flywheel: state.composerFlywheel,
          ),
        composer,
      ],
    );
    final content = Column(
      children: [
        if (messagingFlow)
          Expanded(
            child: showPlanDocumentPanel
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: LicoTopEdgePulse(
                          key: const Key('conversation-header-running-edge'),
                          enabled: state.turnActive || state.loading,
                          borderRadius: BorderRadius.zero,
                          color: colors.primaryStrong,
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              messages,
                              Align(
                                alignment: Alignment.topCenter,
                                child: messagingHeader,
                              ),
                              Align(
                                alignment: Alignment.bottomCenter,
                                child: bottomDock,
                              ),
                            ],
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 300,
                        child: LicoPlanDocumentPanel(
                          planPath: state.planDocumentPath,
                          reader: state.planDocumentReader,
                          refreshToken:
                              state.liveMessages.length +
                              (state.turnActive ? 1 : 0),
                        ),
                      ),
                    ],
                  )
                : LicoTopEdgePulse(
                    key: const Key('conversation-header-running-edge'),
                    enabled: state.turnActive || state.loading,
                    borderRadius: BorderRadius.zero,
                    color: colors.primaryStrong,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        messages,
                        Align(
                          alignment: Alignment.topCenter,
                          child: messagingHeader,
                        ),
                        Align(
                          alignment: Alignment.bottomCenter,
                          child: bottomDock,
                        ),
                      ],
                    ),
                  ),
          )
        else ...[
          header,
          LicoTopEdgePulse(
            key: const Key('conversation-header-running-edge'),
            enabled: state.turnActive || state.loading,
            borderRadius: BorderRadius.zero,
            color: colors.primaryStrong,
            child: const Divider(height: 2),
          ),
          Expanded(child: messages),
          const Divider(height: 1),
          ?sendUnavailable,
          ?sendFailure,
          ?permissionRetry,
          if (showComposerCapsuleRow)
            ComposerCapsuleRow(
              workingDirectory: state.showWorkingDirectory
                  ? state.workingDirectory
                  : null,
              workingDirectorySelectable: state.workingDirectorySelectable,
              onChooseWorkingDirectory: actions.onChooseWorkingDirectory,
              modelOptions: state.modelOptions,
              selectedModel: state.selectedModel,
              defaultModel: state.defaultModel,
              modelSelectionEnabled: state.composerEnabled,
              onModelChanged: actions.onModelChanged,
              reasoningEffortOptions: state.reasoningEffortOptions,
              selectedReasoningEffort: state.selectedReasoningEffort,
              defaultReasoningEffort: state.defaultReasoningEffort,
              onReasoningEffortChanged: actions.onReasoningEffortChanged,
              licoProfileCapsule: licoProfileCapsule,
              flywheel: state.composerFlywheel,
            ),
          composer,
        ],
      ],
    );
    // Messaging capsules float on the glass canvas — PanelFrame's surface
    // band + border would reintroduce a full-width header partition.
    final useFrame = framed && !messagingFlow;
    final pane = useFrame ? PanelFrame(child: content) : content;
    // Every text in the conversation pane is selectable for copy.
    return SelectionArea(child: pane);
  }
}

class _ConversationSendFailureRow extends StatelessWidget {
  const _ConversationSendFailureRow({
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Padding(
      key: const Key('conversation-send-failed'),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(Icons.error_outline_rounded, size: 14, color: colors.error),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              message,
              key: const Key('conversation-send-failed-reason'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: colors.error,
                fontSize: 12,
                fontWeight: FontWeight.w500,
                height: 1.25,
              ),
            ),
          ),
          if (actionLabel != null)
            TextButton(
              key: const Key('conversation-send-failed-action'),
              onPressed: onAction,
              style: TextButton.styleFrom(
                foregroundColor: colors.accent,
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                textStyle: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              child: Text(actionLabel!),
            ),
        ],
      ),
    );
  }
}

class _ConversationPermissionRetryRow extends StatelessWidget {
  const _ConversationPermissionRetryRow({
    required this.tool,
    this.onAllow,
    this.onAllowAndRemember,
    this.onDeny,
  });

  final String tool;
  final VoidCallback? onAllow;
  final VoidCallback? onAllowAndRemember;
  final VoidCallback? onDeny;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    return Padding(
      key: const Key('conversation-permission-retry'),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(Icons.security_rounded, size: 14, color: colors.warning),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              strings.conversationPermissionDenied(tool),
              key: const Key('conversation-permission-retry-reason'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: colors.textMuted,
                fontSize: 12,
                fontWeight: FontWeight.w500,
                height: 1.25,
              ),
            ),
          ),
          TextButton(
            key: const Key('conversation-permission-retry-action'),
            onPressed: onAllow,
            style: TextButton.styleFrom(
              foregroundColor: colors.accent,
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              textStyle: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            child: Text(strings.conversationPermissionAllowAction),
          ),
          TextButton(
            key: const Key('conversation-permission-retry-remember'),
            onPressed: onAllowAndRemember,
            style: TextButton.styleFrom(
              foregroundColor: colors.accent,
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              textStyle: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            child: Text(strings.conversationPermissionAllowAndRememberAction),
          ),
          TextButton(
            key: const Key('conversation-permission-retry-deny'),
            onPressed: onDeny,
            style: TextButton.styleFrom(
              foregroundColor: colors.textMuted,
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              textStyle: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            child: Text(strings.conversationPermissionDenyAction),
          ),
        ],
      ),
    );
  }
}

class _ConversationSendUnavailableRow extends StatelessWidget {
  const _ConversationSendUnavailableRow({required this.copy, this.onUnblock});

  final ConversationSendAvailabilityCopy copy;
  final VoidCallback? onUnblock;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    return Padding(
      key: const Key('conversation-send-unavailable'),
      padding: const EdgeInsets.fromLTRB(16, 8, 12, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(Icons.warning_amber_rounded, size: 14, color: colors.warning),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              copy.reasonLabel,
              key: const Key('conversation-send-unavailable-reason'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: colors.textMuted,
                fontSize: 12,
                fontWeight: FontWeight.w500,
                height: 1.25,
              ),
            ),
          ),
          if (copy.unblockAction != null && onUnblock != null)
            TextButton(
              key: const Key('conversation-send-unavailable-action'),
              onPressed: onUnblock,
              style: TextButton.styleFrom(
                foregroundColor: colors.accent,
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                textStyle: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              child: Text(copy.unblockLabel ?? strings.refreshAgents),
            ),
        ],
      ),
    );
  }
}
