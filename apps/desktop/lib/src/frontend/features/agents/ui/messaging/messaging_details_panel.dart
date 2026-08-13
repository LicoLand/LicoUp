import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/agent_conversation_session.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_connection_chips.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_pane_presentation.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_parity_disclosure.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_runtime_settings.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/apple_notifications.dart';
import 'package:licoup/src/frontend/shared/ui/lico_radius.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

/// Messaging details surface: runtime settings, capability disclosure,
/// connection status, and session metadata. Rendered as a hover card on
/// desktop and as a bottom-sheet body on narrow or mobile surfaces.
class MessagingDetailsPanel extends StatelessWidget {
  const MessagingDetailsPanel({
    super.key,
    required this.state,
    required this.actions,
    this.opencodeServeState,
    this.onClose,
    this.forPopover = false,
  });

  final AgentConversationPaneState state;
  final AgentConversationPaneActions actions;
  final AgentConversationServeState? opencodeServeState;

  /// When set (bottom-sheet usage), a close affordance is shown.
  final VoidCallback? onClose;

  /// Compact scroll body for hover popovers — no sheet chrome or sidebar fill.
  final bool forPopover;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final body = MessagingDetailsPanelBody(
      state: state,
      actions: actions,
      opencodeServeState: opencodeServeState,
    );

    if (forPopover) {
      return Column(
        key: const Key('messaging-details-popover'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
            child: Text(
              strings.details,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: context.licoColors.text,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          body,
        ],
      );
    }

    final colors = context.licoColors;
    return ColoredBox(
      key: const Key('messaging-details-panel'),
      color: colors.surfaceLow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    strings.details,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.text,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (onClose != null)
                  IconButton(
                    key: const Key('messaging-details-close'),
                    tooltip: strings.close,
                    onPressed: onClose,
                    icon: Icon(
                      Icons.close_rounded,
                      size: 18,
                      color: colors.textMuted,
                    ),
                  ),
              ],
            ),
          ),
          Expanded(child: body),
        ],
      ),
    );
  }
}

/// Scrollable details sections shared by popover and sheet presentations.
class MessagingDetailsPanelBody extends StatelessWidget {
  const MessagingDetailsPanelBody({
    super.key,
    required this.state,
    required this.actions,
    this.opencodeServeState,
  });

  final AgentConversationPaneState state;
  final AgentConversationPaneActions actions;
  final AgentConversationServeState? opencodeServeState;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final session = state.session;
    final connectionChips = conversationConnectionChipChildren(
      target: state.target,
      opencodeServeState: opencodeServeState,
      showParity: false,
      chipSpacing: 0,
    );
    final createdAt = session == null
        ? null
        : DateTime.tryParse(session.createdAt)?.toLocal();
    return ListView(
      key: const Key('messaging-details-panel-body'),
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 16),
      children: [
        _MessagingDetailsSection(
          title: strings.runtimeSection,
          child: ConversationRuntimeSettingsBar(
            enabled: state.composerEnabled,
            modelOptions: state.modelOptions,
            selectedModel: state.selectedModel,
            reasoningEffortOptions: state.reasoningEffortOptions,
            selectedReasoningEffort: state.selectedReasoningEffort,
            onModelChanged: actions.onModelChanged,
            onReasoningEffortChanged: actions.onReasoningEffortChanged,
            defaultModel: state.defaultModel,
            defaultReasoningEffort: state.defaultReasoningEffort,
            showWorkingDirectory: state.showWorkingDirectory,
            workingDirectory: state.workingDirectory,
            workingDirectorySelectable: state.workingDirectorySelectable,
            onChooseWorkingDirectory: actions.onChooseWorkingDirectory,
          ),
        ),
        const SizedBox(height: 16),
        _MessagingDetailsSection(
          title: strings.capabilitiesSection,
          child: Align(
            alignment: Alignment.centerLeft,
            child: ConversationParityDisclosurePanel(target: state.target),
          ),
        ),
        if (connectionChips.isNotEmpty) ...[
          const SizedBox(height: 16),
          _MessagingDetailsSection(
            title: strings.connectionSection,
            child: Wrap(spacing: 8, runSpacing: 8, children: connectionChips),
          ),
        ],
        if (session != null) ...[
          const SizedBox(height: 16),
          _MessagingDetailsSection(
            title: strings.sessionSection,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (messagingDetailsConversationId(session).isNotEmpty)
                  _MessagingDetailsCopyRow(
                    label: strings.conversationId,
                    value: messagingDetailsConversationId(session),
                    copiedMessage: strings.conversationIdCopied,
                    onCopyText: actions.onCopyText,
                  ),
                if (session.workingDirectory.trim().isNotEmpty)
                  _MessagingDetailsInfoRow(
                    label: strings.workingDirectory,
                    value: session.workingDirectory.trim(),
                  ),
                if (createdAt != null)
                  _MessagingDetailsInfoRow(
                    label: strings.createdTime,
                    value:
                        '${MaterialLocalizations.of(context).formatMediumDate(createdAt)} '
                        '${MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(createdAt))}',
                  ),
                _MessagingDetailsInfoRow(
                  label: strings.messages,
                  value: strings.messagesCount(session.messageCount),
                ),
              ],
            ),
          ),
        ],
        SizedBox(height: colors.isDark ? 4 : 8),
      ],
    );
  }
}

/// Canonical ID shown in Details and accepted by LicoUp conversation MCP get.
String messagingDetailsConversationId(AgentConversationSession session) {
  final localId = session.id.trim();
  final nativeId = session.nativeSessionId.trim();
  final locallyOwned = session.sourceClient.trim() == 'licoup';
  if (locallyOwned) {
    return localId.isNotEmpty ? localId : nativeId;
  }
  return nativeId.isNotEmpty ? nativeId : localId;
}

/// Conversation ID shown on hover next to a message timestamp for one author.
///
/// Agent bubbles use that agent's native (or local) conversation id. User
/// bubbles omit the id — only the timestamp is revealed.
String messagingHoverConversationId({
  required bool authorIsUser,
  required String participantAgentId,
  required Map<String, String> participantConversationIds,
  required String primaryConversationId,
}) {
  if (authorIsUser) {
    return '';
  }
  final agentId = participantAgentId.trim();
  if (agentId.isNotEmpty) {
    final mapped = participantConversationIds[agentId]?.trim() ?? '';
    if (mapped.isNotEmpty) {
      return mapped;
    }
  }
  return primaryConversationId.trim();
}

class _MessagingDetailsSection extends StatelessWidget {
  const _MessagingDetailsSection({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title.toUpperCase(),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: colors.textMuted,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.8,
          ),
        ),
        const SizedBox(height: 8),
        child,
      ],
    );
  }
}

class _MessagingDetailsInfoRow extends StatelessWidget {
  const _MessagingDetailsInfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: colors.textMuted,
              fontSize: 11.5,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: colors.text,
              fontSize: 12.5,
              fontWeight: FontWeight.w400,
            ),
          ),
        ],
      ),
    );
  }
}

class _MessagingDetailsCopyRow extends StatelessWidget {
  const _MessagingDetailsCopyRow({
    required this.label,
    required this.value,
    required this.copiedMessage,
    required this.onCopyText,
  });

  final String label;
  final String value;
  final String copiedMessage;
  final Future<void> Function(String)? onCopyText;

  Future<void> _copy(BuildContext context) async {
    final write = onCopyText;
    if (write == null) return;
    await write(value);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      appleGlassSnackBar(context: context, message: copiedMessage),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: colors.textMuted,
              fontSize: 11.5,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 2),
          Material(
            color: Colors.transparent,
            child: InkWell(
              key: const Key('messaging-details-conversation-id'),
              borderRadius: BorderRadius.circular(LicoRadius.chip),
              onTap: () => _copy(context),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        value,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.text,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w500,
                          fontFamily: 'Menlo',
                          fontFamilyFallback: const [
                            'Monaco',
                            'Consolas',
                            'monospace',
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Icon(
                      Icons.copy_outlined,
                      size: 14,
                      color: colors.textMuted,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
