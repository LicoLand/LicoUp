import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/client_conversation_models.dart';
import 'package:licoup/src/contracts/provider_quota_models.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_display_names.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_agent_avatar.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_conversation_overlay_glass.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_glass_option_card.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_hover_popover.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_quota_ring.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_quota_usage_card.dart';
import 'package:licoup/src/shared/l10n/lico_strings_catalog.dart';
import 'package:licoup/src/frontend/shared/ui/messaging_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

class CanonicalGroupRoster extends StatelessWidget {
  const CanonicalGroupRoster({
    super.key,
    required this.conversation,
    required this.targets,
    required this.onMentionAgent,
    this.onOpenAgentConversations,
    this.onBoundaryOverscroll,
    this.quotaSnapshots = const <String, ProviderQuotaSnapshot>{},
  });

  final ClientConversation conversation;
  final List<TargetCandidate> targets;
  final ValueChanged<TargetCandidate> onMentionAgent;
  final ValueChanged<TargetCandidate>? onOpenAgentConversations;
  final ValueChanged<double>? onBoundaryOverscroll;

  /// Immutable provider-quota projection keyed by agent id. Members without
  /// an entry render no ring and no hover card — never placeholder data.
  final Map<String, ProviderQuotaSnapshot> quotaSnapshots;

  Future<void> _showAgentMenu({
    required BuildContext context,
    required TargetCandidate target,
    required String label,
    required Offset globalPosition,
  }) async {
    final strings = LicoStrings.of(context);
    final action = await showMessagingGlassMenu<_CanonicalGroupRosterAction>(
      context: context,
      globalPosition: globalPosition,
      menuKey: Key('canonical-group-roster-menu-${target.target}'),
      actions: [
        MessagingGlassMenuAction(
          value: _CanonicalGroupRosterAction.mention,
          label: strings.mentionAgent(label),
          leading: const Icon(Icons.alternate_email_rounded, size: 17),
        ),
        if (onOpenAgentConversations != null)
          MessagingGlassMenuAction(
            value: _CanonicalGroupRosterAction.openConversations,
            label: strings.openAgentConversations(label),
            leading: const Icon(Icons.forum_outlined, size: 17),
          ),
      ],
    );
    switch (action) {
      case _CanonicalGroupRosterAction.mention:
        onMentionAgent(target);
        break;
      case _CanonicalGroupRosterAction.openConversations:
        onOpenAgentConversations?.call(target);
        break;
      case null:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final membershipsByAgentId = {
      for (final membership in conversation.activeAgentMemberships)
        membership.principal.agentId: membership,
    };
    return SizedBox(
      key: const Key('canonical-group-roster'),
      width: MessagingDesktopMetrics.groupRosterExtent,
      child: ScrollConfiguration(
        behavior: const _CanonicalGroupRosterScrollBehavior(),
        child: NotificationListener<OverscrollNotification>(
          onNotification: (notification) {
            if (notification.depth == 0) {
              onBoundaryOverscroll?.call(notification.overscroll);
            }
            return false;
          },
          child: ListView.separated(
            shrinkWrap: true,
            physics: const ClampingScrollPhysics(),
            padding: const EdgeInsets.symmetric(
              horizontal: MessagingDesktopMetrics.groupRosterPadH,
              vertical: MessagingDesktopMetrics.groupRosterVerticalInset,
            ),
            itemCount: targets.length,
            separatorBuilder: (_, _) => const SizedBox(
              height: MessagingDesktopMetrics.groupRosterMemberGap,
            ),
            itemBuilder: (context, index) {
              final target = targets[index];
              final membership =
                  membershipsByAgentId[target.target] ??
                  membershipsByAgentId[target.id];
              final membershipLabel =
                  membership?.principal.displayName.trim() ?? '';
              final fullLabel = membershipLabel.isEmpty
                  ? agentConversationTargetDisplayName(target)
                  : membershipLabel;
              final compactLabel = agentConversationTargetCompactDisplayName(
                target,
              );
              final quotaSnapshot = _renderableQuotaSnapshot(
                quotaSnapshots[target.target] ?? quotaSnapshots[target.id],
              );
              final member = Tooltip(
                message: fullLabel,
                waitDuration: LicoMotion.tooltipWait,
                // Bare avatar + relay dot only; the member name stays in the
                // tooltip so the capsule keeps its true stadium silhouette.
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    key: Key('canonical-group-roster-agent-${target.target}'),
                    behavior: HitTestBehavior.opaque,
                    onTap: () => onMentionAgent(target),
                    onDoubleTap: onOpenAgentConversations == null
                        ? null
                        : () => onOpenAgentConversations!(target),
                    onSecondaryTapDown: (details) => _showAgentMenu(
                      context: context,
                      target: target,
                      label: compactLabel,
                      globalPosition: details.globalPosition,
                    ),
                    // Anchor the relay dot to the avatar box itself: the
                    // ListView stretches items to the capsule width, so a
                    // bare Stack would pin the dot past the icon's edge.
                    child: Center(
                      child: SizedBox.square(
                        dimension:
                            MessagingDesktopMetrics.groupRosterMemberExtent,
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            Positioned.fill(
                              child: quotaSnapshot == null
                                  ? MessagingAgentAvatar(
                                      target: target,
                                      size: MessagingDesktopMetrics
                                          .conversationAvatarExtent,
                                      iconSize: MessagingDesktopMetrics
                                          .conversationAvatarMarkExtent,
                                    )
                                  : MessagingQuotaRing(
                                      key: Key(
                                        'messaging-quota-ring-${target.target}',
                                      ),
                                      snapshot: quotaSnapshot,
                                      child: MessagingAgentAvatar(
                                        target: target,
                                        size: MessagingDesktopMetrics
                                            .groupRosterQuotaAvatarExtent,
                                        iconSize: MessagingDesktopMetrics
                                            .groupRosterQuotaAvatarMarkExtent,
                                      ),
                                    ),
                            ),
                            Positioned(
                              right: 0,
                              bottom: 0,
                              child: Container(
                                key: Key(
                                  'canonical-group-roster-relay-dot-${target.target}',
                                ),
                                width: 10,
                                height: 10,
                                decoration: BoxDecoration(
                                  color: target.canRelayRuntime
                                      ? colors.success
                                      : colors.textDisabled,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: colors.surface,
                                    width: 2,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              );
              if (quotaSnapshot == null) {
                return member;
              }
              // The usage card floats beside the hovered avatar; the capsule
              // itself stays a pure icon list with zero text.
              return MessagingHoverPopover(
                wrapInGlass: false,
                targetAnchor: Alignment.centerLeft,
                followerAnchor: Alignment.centerRight,
                offset: const Offset(-8, 0),
                triggerBuilder:
                    (
                      context, {
                      required open,
                      required toggle,
                      required close,
                    }) => member,
                cardBuilder: (context, close) => MessagingQuotaUsageCard(
                  key: Key('messaging-quota-usage-card-${target.target}'),
                  snapshot: quotaSnapshot,
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

enum _CanonicalGroupRosterAction { mention, openConversations }

/// Only snapshots with usable quota windows render chrome; unavailable or
/// window-less entries behave exactly like a missing snapshot.
ProviderQuotaSnapshot? _renderableQuotaSnapshot(
  ProviderQuotaSnapshot? snapshot,
) {
  return snapshot != null && snapshot.hasQuotaWindows ? snapshot : null;
}

final class _CanonicalGroupRosterScrollBehavior extends MaterialScrollBehavior {
  const _CanonicalGroupRosterScrollBehavior();

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => Scrollbar(
    key: const Key('canonical-group-roster-scrollbar'),
    controller: details.controller,
    thickness: MessagingDesktopMetrics.groupRosterScrollbarThickness,
    radius: const Radius.circular(1),
    interactive: true,
    child: child,
  );
}

/// Detached group-member capsule, centered in the right transcript band and
/// styled with the same glass and width as the header visibility control.
class CanonicalGroupRosterSurface extends StatelessWidget {
  const CanonicalGroupRosterSurface({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    // True stadium: 999 clamps to half the capsule width, so the top and
    // bottom ends are full semicircles at any content height.
    final radius = BorderRadius.circular(999);
    return SizedBox(
      key: const Key('canonical-group-roster-surface'),
      width: MessagingDesktopMetrics.groupRosterExtent,
      child: MessagingConversationOverlayGlass(
        key: const Key('canonical-group-roster-glass'),
        borderRadius: radius,
        child: child,
      ),
    );
  }
}
