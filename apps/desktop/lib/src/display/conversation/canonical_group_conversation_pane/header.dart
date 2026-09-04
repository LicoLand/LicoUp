import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/client_conversation_models.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_conversation_overlay_glass.dart';
import 'package:licoup/src/shared/l10n/lico_strings_catalog.dart';
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
        const SizedBox(width: 10),
        Expanded(
          child: Row(
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
                const SizedBox(width: 6),
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
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: MessagingConversationOverlayGlass(
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
            const SizedBox(
              width: MessagingDesktopMetrics.conversationHeaderCapsuleButtonGap,
            ),
            AspectRatio(
              aspectRatio: 1,
              child: MessagingConversationOverlayGlass(
                key: const Key('canonical-group-roster-toggle-capsule'),
                borderRadius: capsuleRadius,
                child: Center(child: rosterToggle),
              ),
            ),
          ],
        ),
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
      icon: AnimatedSwitcher(
        duration: context.motion(LicoMotion.short),
        switchInCurve: LicoMotion.standard,
        switchOutCurve: LicoMotion.standard,
        child: Icon(
          rosterVisible
              ? Icons.keyboard_arrow_up_rounded
              : Icons.keyboard_arrow_down_rounded,
          key: ValueKey<bool>(rosterVisible),
        ),
      ),
    );
  }
}
