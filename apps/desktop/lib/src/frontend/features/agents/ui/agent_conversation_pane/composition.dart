import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_composer.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_display_names.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_message_view.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_pane_controls.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_pane_presentation.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_parity_disclosure.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_recent_sessions.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/platform/client_platform.dart';
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
  });

  final AgentConversationPaneState state;
  final AgentConversationPaneActions actions;
  final Widget header;
  final bool framed;

  @override
  Widget build(BuildContext context) {
    final mobileClient = isMobileClientPlatform(context);
    final strings = LicoStrings.of(context);
    final unavailableCopy = conversationSendAvailabilityCopy(
      strings: strings,
      reasonCode: state.sendGateReasonCode,
      orchestration:
          state.orchestrationSelected &&
          !state.composerEnabled &&
          state.sendGateReasonCode == 'orchestration_policy_required',
    );
    final composer = RuntimeMessageComposer(
      targetLabel: agentConversationTargetDisplayName(state.target),
      initialDraft: state.composerDraft,
      busy: state.turnActive,
      enabled: state.composerEnabled,
      modelOptions: state.modelOptions,
      selectedModel: state.selectedModel,
      reasoningEffortOptions: state.reasoningEffortOptions,
      selectedReasoningEffort: state.selectedReasoningEffort,
      onModelChanged: actions.onModelChanged,
      onReasoningEffortChanged: actions.onReasoningEffortChanged,
      onDraftChanged: actions.onDraftChanged,
      onSend: actions.onSend,
      defaultModel: state.defaultModel,
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
          )
        : null;
    final messages =
        state.session == null &&
            state.preparingNewConversation &&
            state.liveMessages.isEmpty
        ? AgentConversationRecentSessions(
            sessions: state.recentSessions,
            loading: state.loading,
            onSelectSession: actions.onSelectSession,
          )
        : AgentConversationMessageList(
            loading: state.loading,
            session: state.session,
            target: state.target,
            turnActive: state.turnActive,
            liveMessages: state.liveMessages,
          );
    if (mobileClient) {
      return Column(
        children: [
          if (!state.orchestrationSelected)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: ConversationParityDisclosurePanel(
                  target: state.target,
                  compact: true,
                ),
              ),
            ),
          Expanded(child: messages),
          ?sendUnavailable,
          ?sendFailure,
          MobileComposerSurface(child: composer),
        ],
      );
    }
    final content = Column(
      children: [
        header,
        const Divider(height: 1),
        Expanded(child: messages),
        ?sendUnavailable,
        ?sendFailure,
        const Divider(height: 1),
        composer,
      ],
    );
    return framed ? PanelFrame(child: content) : content;
  }
}

class _ConversationSendFailureRow extends StatelessWidget {
  const _ConversationSendFailureRow({required this.message});

  final String message;

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
                foregroundColor: colors.primary,
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
