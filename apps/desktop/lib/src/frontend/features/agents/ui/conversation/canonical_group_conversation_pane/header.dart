import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/client_conversation_models.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_conversation_header_bar.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_conversation_overlay_glass.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_conversation_menu.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_group_mosaic_avatar.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_header_directive_controls.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/messaging_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/platform/client_platform.dart';
import 'package:licoup/src/frontend/shared/ui/lico_icon_button.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

class CanonicalGroupConversationHeader extends StatelessWidget {
  const CanonicalGroupConversationHeader({
    super.key,
    required this.conversation,
    required this.rosterVisible,
    required this.onToggleRoster,
    this.memberCount = 0,
    this.rosterTargets = const [],
    this.selfMascotId,
    this.presenceLabel,
  });

  final ClientConversation conversation;
  final bool rosterVisible;
  final VoidCallback onToggleRoster;

  /// Members listed by the roster, the local user included. The flat header
  /// bar shows it under the title.
  final int memberCount;

  /// Agent targets listed by the roster; the first few fill the header's
  /// 2x2 member mosaic beside the local user's cell.
  final List<TargetCandidate> rosterTargets;

  /// The local user's mascot pick, matching the roster's self avatar.
  final String? selfMascotId;

  /// Trailing presence segment under the title, e.g. "Lico 助手在线".
  final String? presenceLabel;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final colors = context.licoColors;
    final title = conversation.title.trim().isEmpty
        ? strings.groupConversation
        : conversation.title.trim();
    final subtitle = memberCount > 0
        ? presenceLabel == null
              ? strings.groupConversationMemberCount(memberCount)
              : '${strings.groupConversationMemberCount(memberCount)}'
                    ' · $presenceLabel'
        : (presenceLabel ?? '');
    final avatar = KeyedSubtree(
      key: const Key('canonical-group-header-avatar'),
      child: MessagingGroupMosaicAvatar(
        rosterTargets: rosterTargets,
        selfMascotId: selfMascotId,
        hasLocalOwner: conversation.localOwnerMembership != null,
        extent: messagingConversationHeaderUsesBar(context)
            ? messagingConversationHeaderBarAvatarExtentOf(context)
            : MessagingDesktopMetrics.conversationAvatarExtent,
      ),
    );
    if (messagingConversationHeaderUsesBar(context)) {
      return MessagingConversationHeaderBar(
        avatar: avatar,
        title: title,
        subtitle: subtitle,
        switcherTriggerKey: const Key('canonical-group-switcher-trigger'),
        actions: [
          LicoIconButton(
            key: const Key('canonical-group-members-toggle'),
            tooltip: rosterVisible
                ? strings.hideGroupMembers
                : strings.showGroupMembers,
            onPressed: onToggleRoster,
            size: LicoIconButtonSize.compact,
            selected: rosterVisible,
            icon: const Icon(Icons.people_alt_outlined),
          ),
        ],
      );
    }
    final identity = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        avatar,
        const SizedBox(width: 14),
        Flexible(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
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
              if (subtitle.isNotEmpty)
                Flexible(
                  child: Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: colors.textMuted, fontSize: 11),
                  ),
                ),
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
                  padding: const EdgeInsets.only(
                    left: MessagingDesktopMetrics.conversationHeaderCapsulePadV,
                    right:
                        MessagingDesktopMetrics.conversationHeaderCapsulePadH,
                    top: MessagingDesktopMetrics.conversationHeaderCapsulePadV,
                    bottom:
                        MessagingDesktopMetrics.conversationHeaderCapsulePadV,
                  ),
                  child: MessagingHeaderSwitcherTrigger(
                    triggerKey: const Key('canonical-group-switcher-trigger'),
                    identity: identity,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(
            width: MessagingDesktopMetrics.conversationHeaderCapsuleButtonGap,
          ),
          LicoIconButton(
            key: const Key('canonical-group-members-toggle'),
            tooltip: rosterVisible
                ? strings.hideGroupMembers
                : strings.showGroupMembers,
            onPressed: onToggleRoster,
            size: LicoIconButtonSize.compact,
            selected: rosterVisible,
            icon: const Icon(Icons.people_alt_outlined),
          ),
          const SizedBox(
            width: MessagingDesktopMetrics.conversationHeaderCapsuleButtonGap,
          ),
          MessagingConversationMenu(
            triggerKey: const Key('canonical-group-menu-button'),
            panelKey: const Key('canonical-group-menu-panel'),
            childrenBuilder: (close) {
              return [
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
              ];
            },
          ),
          const MessagingHeaderCollapseControl(),
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
      size: LicoIconButtonSize.compact,
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
