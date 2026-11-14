import 'dart:async';

import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_display_names.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_pane_presentation.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_agent_avatar.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_conversation_header_bar.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_conversation_overlay_glass.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_conversation_history_menu.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_conversation_menu.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_details_panel.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_header_directive_controls.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/platform/client_platform.dart';
import 'package:licoup/src/frontend/shared/ui/lico_icon_button.dart';
import 'package:licoup/src/frontend/shared/ui/messaging_desktop_tokens.dart';
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
    this.historySessions,
    this.historySelectedSessionId = '',
    this.onSelectHistorySession,
    this.onNewHistoryConversation,
    this.historyRunningFor,
    this.onBackToGroup,
  });

  final TargetCandidate target;
  final AgentConversationSession? session;
  final AgentConversationPaneState detailsState;
  final AgentConversationPaneActions detailsActions;
  final AgentConversationServeState? opencodeServeState;

  /// Sessions for the header History button. When null the button is hidden
  /// (group chats pass null; member-in-group sessions show no "New
  /// conversation" row through a null [onNewHistoryConversation]).
  final List<AgentConversationSession>? historySessions;
  final String historySelectedSessionId;
  final ValueChanged<String>? onSelectHistorySession;
  final VoidCallback? onNewHistoryConversation;
  final bool Function(AgentConversationSession session)? historyRunningFor;

  /// Member-session view inside a group: returns to the group conversation.
  final VoidCallback? onBackToGroup;

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
            ..._trailingActions(context: context, strings: strings),
          ],
        ),
      );
    }

    if (messagingConversationHeaderUsesBar(context)) {
      return MessagingConversationHeaderBar(
        avatar: MessagingAgentAvatar(
          target: target,
          size: messagingConversationHeaderBarAvatarExtentOf(context),
          iconSize: messagingConversationHeaderBarAvatarMarkExtent,
        ),
        title: headerTitle,
        subtitle: headerSubtitle,
        actions: [
          if (onBackToGroup != null)
            Builder(
              builder: (buttonContext) => LicoIconButton(
                key: const Key('messaging-conversation-back-to-group'),
                tooltip: strings.backToGroup,
                onPressed: onBackToGroup!,
                size: LicoIconButtonSize.compact,
                icon: const Icon(Icons.arrow_back_rounded),
              ),
            ),
          if (_showsHistory)
            Builder(
              builder: (buttonContext) => LicoIconButton(
                key: const Key('messaging-conversation-history'),
                tooltip: strings.historyConversations,
                onPressed: () => _openHistory(buttonContext),
                size: LicoIconButtonSize.compact,
                icon: const Icon(Icons.history_rounded),
              ),
            ),
          _menu(context: context, strings: strings, flat: true),
        ],
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
          if (onBackToGroup != null) ...[
            const SizedBox(
              width: MessagingDesktopMetrics.conversationHeaderCapsuleButtonGap,
            ),
            _capsuleHeaderButton(
              context: context,
              buttonKey: const Key('messaging-conversation-back-to-group'),
              tooltip: strings.backToGroup,
              icon: Icons.arrow_back_rounded,
              onPressed: onBackToGroup!,
            ),
          ],
          if (_showsHistory) ...[
            const SizedBox(
              width: MessagingDesktopMetrics.conversationHeaderCapsuleButtonGap,
            ),
            Builder(
              builder: (buttonContext) => _capsuleHeaderButton(
                context: context,
                buttonKey: const Key('messaging-conversation-history'),
                tooltip: strings.historyConversations,
                icon: Icons.history_rounded,
                onPressed: () => _openHistory(buttonContext),
              ),
            ),
          ],
          const SizedBox(
            width: MessagingDesktopMetrics.conversationHeaderCapsuleButtonGap,
          ),
          _menu(context: context, strings: strings, flat: false),
          const MessagingHeaderCollapseControl(),
        ],
      ),
    );
  }

  Widget _menu({
    required BuildContext context,
    required LicoStrings strings,
    required bool flat,
  }) => MessagingConversationMenu(
    triggerKey: const Key('messaging-conversation-menu-button'),
    panelKey: const Key('messaging-conversation-menu-panel'),
    flatTrigger: flat,
    childrenBuilder: (close) {
      return [
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
                    height: MediaQuery.sizeOf(dialogContext).height * 0.7,
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
      ];
    },
  );

  bool get _showsHistory =>
      historySessions != null && onSelectHistorySession != null;

  void _openHistory(BuildContext anchorContext) {
    final sessions = historySessions;
    final select = onSelectHistorySession;
    if (sessions == null || select == null) return;
    final box = anchorContext.findRenderObject();
    final position = box is RenderBox
        ? box.localToGlobal(Offset(0, box.size.height + 4))
        : Offset.zero;
    unawaited(
      showMessagingConversationHistoryMenu(
        context: anchorContext,
        globalPosition: position,
        sessions: sessions,
        selectedSessionId: historySelectedSessionId,
        onSelect: select,
        onNewConversation: onNewHistoryConversation,
        runningFor: historyRunningFor,
      ),
    );
  }

  /// A quiet circular glass capsule button for the floating header row.
  Widget _capsuleHeaderButton({
    required BuildContext context,
    required Key buttonKey,
    required String tooltip,
    required IconData icon,
    required VoidCallback onPressed,
  }) {
    return MessagingConversationOverlayGlass(
      borderRadius: BorderRadius.circular(999),
      child: SizedBox.square(
        dimension: MessagingDesktopMetrics.conversationHeaderMenuExtent,
        child: IconButton(
          key: buttonKey,
          tooltip: tooltip,
          onPressed: onPressed,
          icon: Icon(icon, size: 19),
        ),
      ),
    );
  }

  List<Widget> _trailingActions({
    required BuildContext context,
    required LicoStrings strings,
  }) => [
    if (onBackToGroup != null)
      IconButton(
        key: const Key('messaging-conversation-back-to-group'),
        tooltip: strings.backToGroup,
        onPressed: onBackToGroup!,
        icon: const Icon(Icons.arrow_back_rounded, size: 19),
      ),
    if (_showsHistory)
      Builder(
        builder: (buttonContext) => IconButton(
          key: const Key('messaging-conversation-history'),
          tooltip: strings.historyConversations,
          onPressed: () => _openHistory(buttonContext),
          icon: const Icon(Icons.history_rounded, size: 19),
        ),
      ),
    IconButton(
      key: const Key('messaging-details-toggle'),
      tooltip: strings.details,
      onPressed: () => _openDetailsSheet(context),
      icon: const Icon(Icons.info_outline_rounded, size: 19),
    ),
  ];
}
