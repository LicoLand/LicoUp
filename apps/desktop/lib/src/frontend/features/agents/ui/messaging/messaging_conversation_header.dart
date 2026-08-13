import 'dart:async';

import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_display_names.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_pane_presentation.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_agent_avatar.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_conversation_overlay_glass.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_conversation_switcher.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_details_panel.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_hover_popover.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/tokens/messaging_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/platform/client_platform.dart';
import 'package:licoup/src/frontend/shared/ui/apple_control_metrics.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/frontend/shared/ui/theme_colors.dart';

/// Messaging conversation header: adaptive-width identity capsule on the
/// left, spaced capsule icon buttons on the right — not a full-width top bar.
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
      children: [
        MessagingAgentAvatar(target: target, size: 30, iconSize: 17),
        const SizedBox(width: 10),
        Expanded(
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
              colors: colors,
              strings: strings,
              sessions: sessions,
              mobileClient: mobileClient,
              capsuleButtons: false,
            ),
          ],
        ),
      );
    }

    final radius = BorderRadius.circular(
      MessagingDesktopMetrics.conversationHeaderCapsuleCornerRadius,
    );
    final identityCapsule = MessagingConversationOverlayGlass(
      borderRadius: radius,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: MessagingDesktopMetrics.conversationHeaderCapsulePadH,
          vertical: MessagingDesktopMetrics.conversationHeaderCapsulePadV,
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
      // Match trailing button height (and thus end-cap radius) to the
      // identity capsule — same corner radius token on both.
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: identityCapsule),
            SizedBox(
              width: MessagingDesktopMetrics.conversationHeaderCapsuleButtonGap,
            ),
            ..._trailingActions(
              context: context,
              colors: colors,
              strings: strings,
              sessions: sessions,
              mobileClient: mobileClient,
              capsuleButtons: true,
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _trailingActions({
    required BuildContext context,
    required LicoThemeColors colors,
    required LicoStrings strings,
    required List<AgentConversationSession>? sessions,
    required bool mobileClient,
    required bool capsuleButtons,
  }) {
    final gap = SizedBox(
      width: MessagingDesktopMetrics.conversationHeaderCapsuleButtonGap,
    );
    final actions = <Widget>[];

    if (sessions != null &&
        onSwitchConversation != null &&
        onSwitchNewConversation != null) {
      final switcher = MessagingConversationSwitcher(
        sessions: sessions,
        selectedSessionId: switcherSelectedSessionId,
        onSelectConversation: onSwitchConversation!,
        onNewConversation: onSwitchNewConversation!,
        runningFor: switcherRunningFor,
        useBottomSheet: mobileClient,
      );
      actions.add(
        capsuleButtons ? _HeaderCapsuleButton(child: switcher) : switcher,
      );
    }

    final detailsTrigger = _DetailsTrigger(
      strings: strings,
      colors: colors,
      capsuleButtons: capsuleButtons,
      mobileClient: mobileClient,
      onOpenSheet: () => _openDetailsSheet(context),
      detailsState: detailsState,
      detailsActions: detailsActions,
      opencodeServeState: opencodeServeState,
    );
    actions.add(
      capsuleButtons
          ? _HeaderCapsuleButton(child: detailsTrigger)
          : detailsTrigger,
    );

    if (actions.isEmpty) {
      return const [];
    }
    final spaced = <Widget>[actions.first];
    for (var i = 1; i < actions.length; i++) {
      spaced
        ..add(gap)
        ..add(actions[i]);
    }
    return spaced;
  }
}

class _DetailsTrigger extends StatelessWidget {
  const _DetailsTrigger({
    required this.strings,
    required this.colors,
    required this.capsuleButtons,
    required this.mobileClient,
    required this.onOpenSheet,
    required this.detailsState,
    required this.detailsActions,
    this.opencodeServeState,
  });

  final LicoStrings strings;
  final LicoThemeColors colors;
  final bool capsuleButtons;
  final bool mobileClient;
  final VoidCallback onOpenSheet;
  final AgentConversationPaneState detailsState;
  final AgentConversationPaneActions detailsActions;
  final AgentConversationServeState? opencodeServeState;

  Widget _buildButton({required bool open, VoidCallback? onTap}) {
    return Tooltip(
      message: strings.details,
      waitDuration: const Duration(milliseconds: 400),
      child: InkWell(
        key: const Key('messaging-details-toggle'),
        onTap: onTap,
        customBorder: capsuleButtons
            ? RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(
                  MessagingDesktopMetrics.conversationHeaderCapsuleCornerRadius,
                ),
              )
            : const CircleBorder(),
        hoverColor: colors.isDark
            ? Colors.white.withAlpha(10)
            : Colors.black.withAlpha(12),
        child: SizedBox.square(
          dimension: capsuleButtons
              ? MessagingDesktopMetrics.conversationHeaderCapsuleButtonExtent
              : 32,
          child: Icon(
            Icons.info_outline_rounded,
            size: 19,
            color: open ? colors.accent : colors.textMuted,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (mobileClient) {
      return _buildButton(open: false, onTap: onOpenSheet);
    }

    final menuRadius = BorderRadius.circular(
      AppleControlMetrics.menuCornerRadius,
    );
    return MessagingHoverPopover(
      popoverKey: const Key('messaging-details-popover-panel'),
      width: 340,
      maxHeight: 480,
      borderRadius: menuRadius,
      cardBuilder: (context, close) {
        return MessagingDetailsPanel(
          state: detailsState,
          actions: detailsActions,
          opencodeServeState: opencodeServeState,
          forPopover: true,
        );
      },
      triggerBuilder:
          (context, {required open, required toggle, required close}) {
            return _buildButton(open: open, onTap: toggle);
          },
    );
  }
}

/// Square glass control whose height matches the identity capsule
/// ([IntrinsicHeight] + stretch) and whose corner radius uses the same
/// [MessagingDesktopMetrics.conversationHeaderCapsuleCornerRadius].
class _HeaderCapsuleButton extends StatelessWidget {
  const _HeaderCapsuleButton({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(
      MessagingDesktopMetrics.conversationHeaderCapsuleCornerRadius,
    );
    return AspectRatio(
      aspectRatio: 1,
      child: MessagingConversationOverlayGlass(
        borderRadius: radius,
        child: Center(child: child),
      ),
    );
  }
}
