import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/client_conversation_models.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_conversation_overlay_glass.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_conversation_menu.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/messaging_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/platform/client_platform.dart';
import 'package:licoup/src/frontend/shared/ui/conversation_visual_tokens.dart';
import 'package:licoup/src/frontend/shared/ui/lico_icon_button.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

class CanonicalGroupConversationHeader extends StatelessWidget {
  const CanonicalGroupConversationHeader({
    super.key,
    required this.conversation,
    required this.rosterVisible,
    required this.onToggleRoster,
  });

  final ClientConversation conversation;
  final bool rosterVisible;
  final VoidCallback onToggleRoster;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final colors = context.licoColors;
    final title = conversation.title.trim().isEmpty
        ? strings.groupConversation
        : conversation.title.trim();
    final identity = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          key: const Key('canonical-group-header-avatar'),
          width: MessagingDesktopMetrics.conversationAvatarExtent,
          height: MessagingDesktopMetrics.conversationAvatarExtent,
          decoration: BoxDecoration(
            color: ConversationVisualTokens.circularIdentityWellFill(colors),
            shape: BoxShape.circle,
          ),
          child: Icon(
            Icons.groups_2_rounded,
            color: ConversationVisualTokens.groupIdentityMark(colors),
            size: MessagingDesktopMetrics.conversationAvatarMarkExtent,
          ),
        ),
        const SizedBox(width: 14),
        Flexible(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.text,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (conversation.pinned) ...[
                const SizedBox(width: 12),
                Icon(Icons.push_pin_rounded, size: 13, color: colors.textMuted),
              ],
            ],
          ),
        ),
      ],
    );
    final rosterToggle = _CanonicalGroupRosterToggleButton(
      rosterVisible: rosterVisible,
      onPressed: onToggleRoster,
    );
    if (isMobileClientPlatform(context)) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Expanded(child: identity),
            rosterToggle,
          ],
        ),
      );
    }
    // True stadium on both capsules: 999 clamps to half the capsule height,
    // so the ends are full semicircles at any content height.
    final capsuleRadius = BorderRadius.circular(999);
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
              child: MessagingConversationOverlayGlass(
                key: const Key('canonical-group-identity-capsule'),
                borderRadius: capsuleRadius,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal:
                        MessagingDesktopMetrics.conversationHeaderCapsulePadH,
                    vertical:
                        MessagingDesktopMetrics.conversationHeaderCapsulePadV,
                  ),
                  child: identity,
                ),
              ),
            ),
          ),
          const SizedBox(
            width: MessagingDesktopMetrics.conversationHeaderCapsuleButtonGap,
          ),
          MessagingConversationMenu(
            triggerKey: const Key('canonical-group-menu-button'),
            panelKey: const Key('canonical-group-menu-panel'),
            childrenBuilder: (close) => [
              MenuItemButton(
                key: const Key('canonical-group-roster-toggle'),
                leadingIcon: const Icon(Icons.groups_2_outlined),
                onPressed: () {
                  close();
                  onToggleRoster();
                },
                child: Text(
                  rosterVisible
                      ? strings.collapseAgentsSidebar
                      : strings.expandAgentsSidebar,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

final class _CanonicalGroupRosterToggleButton extends StatelessWidget {
  const _CanonicalGroupRosterToggleButton({
    required this.rosterVisible,
    required this.onPressed,
  });

  final bool rosterVisible;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    return LicoIconButton(
      key: const Key('canonical-group-roster-toggle'),
      tooltip: rosterVisible
          ? strings.collapseAgentsSidebar
          : strings.expandAgentsSidebar,
      onPressed: onPressed,
      size: LicoIconButtonSize.large,
      shape: LicoIconButtonShape.circle,
      tone: LicoIconButtonTone.ghost,
      icon: AnimatedRotation(
        turns: rosterVisible ? 0 : 0.5,
        duration: context.motion(LicoMotion.short),
        curve: LicoMotion.standard,
        child: const Icon(Icons.keyboard_arrow_up_rounded),
      ),
    );
  }
}
