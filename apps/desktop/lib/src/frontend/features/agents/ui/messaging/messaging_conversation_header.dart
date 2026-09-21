import 'dart:async';

import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_display_names.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_pane_presentation.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_agent_avatar.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_conversation_overlay_glass.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_conversation_switcher.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_conversation_menu.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_details_panel.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_agents_directive.dart';
import 'package:licoup/src/frontend/shared/ui/messaging_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/platform/client_platform.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

/// Messaging conversation header: adaptive-width identity capsule on the
/// left and a single overflow menu on the right.
class MessagingConversationHeader extends StatelessWidget {
  const MessagingConversationHeader({
    super.key,
    required this.target,
    required this.session,
    required this.detailsState,
    required this.detailsActions,
    this.opencodeServeState,
    this.switcherSessions,
    this.switcherSelectedSessionId = '',
    this.onSwitchConversation,
    this.onSwitchNewConversation,
    this.switcherRunningFor,
  });

  final TargetCandidate target;
  final AgentConversationSession? session;
  final AgentConversationPaneState detailsState;
  final AgentConversationPaneActions detailsActions;
  final AgentConversationServeState? opencodeServeState;

  /// Conversations of the current agent for the in-chat switcher. When null,
  /// the switcher button is not shown.
  final List<AgentConversationSession>? switcherSessions;
  final String switcherSelectedSessionId;
  final ValueChanged<String>? onSwitchConversation;
  final VoidCallback? onSwitchNewConversation;
  final bool Function(AgentConversationSession session)? switcherRunningFor;

  void _openDetailsSheet(BuildContext context) {
    unawaited(
      showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (sheetContext) => SafeArea(
          child: SizedBox(
            height: MediaQuery.of(sheetContext).size.height * 0.66,
            child: MessagingDetailsPanel(
              state: detailsState,
              actions: detailsActions,
              opencodeServeState: opencodeServeState,
              onClose: () => Navigator.of(sheetContext).pop(),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final agentName = agentConversationTargetDisplayName(target);
    final sessionTitle = session?.title.trim();
    final hasSessionTitle = sessionTitle != null && sessionTitle.isNotEmpty;
    final headerTitle = hasSessionTitle ? sessionTitle : agentName;
    final headerSubtitle = hasSessionTitle
        ? agentName
        : (target.kind.trim().isEmpty ? target.target : target.kind.trim());
    final mobileClient = isMobileClientPlatform(context);
    final sessions = switcherSessions;

    final identity = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        MessagingAgentAvatar(
          target: target,
          size: MessagingDesktopMetrics.conversationAvatarExtent,
          iconSize: MessagingDesktopMetrics.conversationAvatarMarkExtent,
        ),
        const SizedBox(width: 14),
        Flexible(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                headerTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: colors.text,
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                  height: 1.15,
                ),
              ),
              if (headerSubtitle.isNotEmpty)
                Text(
                  headerSubtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.textMuted,
                    fontWeight: FontWeight.w500,
                    fontSize: 11,
                    height: 1.2,
                  ),
                ),
            ],
          ),
        ),
      ],
    );

    if (mobileClient) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Expanded(child: identity),
            ..._trailingActions(
              context: context,
              strings: strings,
              sessions: sessions,
            ),
          ],
        ),
      );
    }

    // True stadium: 999 clamps to half the capsule height, so the ends are
    // full semicircles at any content height.
    final radius = BorderRadius.circular(999);
    final identityCapsule = MessagingConversationOverlayGlass(
      key: const Key('messaging-conversation-identity-capsule'),
      borderRadius: radius,
      child: Padding(
        padding: const EdgeInsets.only(
          left: MessagingDesktopMetrics.conversationHeaderCapsulePadV,
          right: MessagingDesktopMetrics.conversationHeaderCapsulePadH,
          top: MessagingDesktopMetrics.conversationHeaderCapsulePadV,
          bottom: MessagingDesktopMetrics.conversationHeaderCapsulePadV,
        ),
        child: identity,
      ),
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        MessagingDesktopMetrics.conversationHeaderCapsuleInsetH,
        MessagingDesktopMetrics.conversationHeaderCapsuleInsetV,
        MessagingDesktopMetrics.conversationHeaderCapsuleInsetH,
        MessagingDesktopMetrics.conversationHeaderCapsuleInsetV,
      ),
      child: Row(
        children: [
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              heightFactor: 1,
              child: identityCapsule,
            ),
          ),
          const SizedBox(
            width: MessagingDesktopMetrics.conversationHeaderCapsuleButtonGap,
          ),
          MessagingConversationMenu(
            triggerKey: const Key('messaging-conversation-menu-button'),
            panelKey: const Key('messaging-conversation-menu-panel'),
            childrenBuilder: (close) {
              final directive = LayoutAgentsDirectiveScope.maybeOf(context);
              return [
                if (directive?.onToggleHistoryList != null)
                  MenuItemButton(
                    key: const Key('messaging-history-list-toggle'),
                    leadingIcon: const Icon(Icons.history_rounded),
                    onPressed: () {
                      close();
                      directive!.onToggleHistoryList!();
                    },
                    child: Text(strings.historyConversations),
                  ),
                MenuItemButton(
                  key: const Key('messaging-details-toggle'),
                  leadingIcon: const Icon(Icons.info_outline_rounded),
                  onPressed: () {
                    close();
                    unawaited(
                      showDialog<void>(
                        context: context,
                        builder: (dialogContext) => Dialog(
                          child: SizedBox(
                            width: 340,
                            height:
                                MediaQuery.sizeOf(dialogContext).height * 0.7,
                            child: MessagingDetailsPanel(
                              state: detailsState,
                              actions: detailsActions,
                              opencodeServeState: opencodeServeState,
                              onClose: () => Navigator.of(dialogContext).pop(),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                  child: Text(strings.details),
                ),
                if (sessions != null &&
                    onSwitchConversation != null &&
                    onSwitchNewConversation != null) ...[
                  const Divider(height: 1),
                  MessagingConversationSwitcherContent(
                    sessions: sessions,
                    selectedSessionId: switcherSelectedSessionId,
                    runningFor: switcherRunningFor,
                    onSelectConversation: (id) {
                      close();
                      onSwitchConversation!(id);
                    },
                    onNewConversation: () {
                      close();
                      onSwitchNewConversation!();
                    },
                  ),
                ],
              ];
            },
          ),
        ],
      ),
    );
  }

  List<Widget> _trailingActions({
    required BuildContext context,
    required LicoStrings strings,
    required List<AgentConversationSession>? sessions,
  }) => [
    if (sessions != null &&
        onSwitchConversation != null &&
        onSwitchNewConversation != null)
      MessagingConversationSwitcher(
        sessions: sessions,
        selectedSessionId: switcherSelectedSessionId,
        onSelectConversation: onSwitchConversation!,
        onNewConversation: onSwitchNewConversation!,
        runningFor: switcherRunningFor,
      ),
    IconButton(
      key: const Key('messaging-details-toggle'),
      tooltip: strings.details,
      onPressed: () => _openDetailsSheet(context),
      icon: const Icon(Icons.info_outline_rounded, size: 19),
    ),
  ];
}
