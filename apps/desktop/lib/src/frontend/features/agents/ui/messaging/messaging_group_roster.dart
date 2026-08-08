import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/group_conversation_models.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_agent_avatar.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_conversation_overlay_glass.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/tokens/messaging_desktop_tokens.dart';

/// Vertical Flywheel agent roster capsule on the right edge of the
/// conversation canvas. Human/"You" entries are omitted — only agent peers
/// are shown. Black readability veil + shared overlay glass form the mask.
class MessagingGroupRoster extends StatelessWidget {
  const MessagingGroupRoster({
    super.key,
    required this.participants,
    required this.targetsByAgentId,
  });

  final List<GroupParticipant> participants;
  final Map<String, TargetCandidate> targetsByAgentId;

  static const double _avatarSize = 28;
  static const double _iconSize = 16;
  static const double _avatarGap = 8;
  static const double _capsulePadH = 8;
  static const double _capsulePadV = 10;

  @override
  Widget build(BuildContext context) {
    final agents = [
      for (final participant in participants)
        if (participant.kind == GroupParticipantKind.agent) participant,
    ];
    if (agents.isEmpty) return const SizedBox.shrink();

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final radius = BorderRadius.circular(
      MessagingDesktopMetrics.conversationHeaderCapsuleCornerRadius,
    );
    // Sized to the capsule only — parent must place this with
    // Positioned.fill + Align.centerRight (or equivalent), otherwise a Stack
    // will park the shrink-wrapped child at top-start (left).
    return ConstrainedBox(
      key: const Key('messaging-group-roster'),
      constraints: const BoxConstraints(maxHeight: 420),
      child: MessagingConversationOverlayGlass(
        borderRadius: radius,
        readabilityVeil: true,
        // Same black-mask family as the main conversation reading surface.
        veilFill: MessagingDesktopMetrics.mainContentCardFill(isDark: isDark),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: _capsulePadH,
            vertical: _capsulePadV,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < agents.length; i++) ...[
                  if (i > 0) const SizedBox(height: _avatarGap),
                  Tooltip(
                    message: agents[i].displayName,
                    waitDuration: const Duration(milliseconds: 400),
                    child: MessagingAgentAvatar(
                      target: targetsByAgentId[agents[i].agentId ?? ''],
                      size: _avatarSize,
                      iconSize: _iconSize,
                      showWell: false,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
