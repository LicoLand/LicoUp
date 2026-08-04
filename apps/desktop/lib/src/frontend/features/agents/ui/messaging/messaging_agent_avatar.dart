import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/agent_conversation_tab_activity.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/shared/ui/agent_brand_icon.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

/// Circular agent brand avatar with the shared activity-dot semantics (amber
/// for needs-approval, blue for finished work) used by every messaging
/// surface.
class MessagingAgentAvatar extends StatelessWidget {
  const MessagingAgentAvatar({
    super.key,
    required this.target,
    this.activity = AgentConversationTabActivity.none,
    this.size = 40,
    this.iconSize = 22,
    this.onSolidAccent = false,
  });

  final TargetCandidate? target;
  final AgentConversationTabActivity activity;
  final double size;
  final double iconSize;

  /// When the avatar sits on a solid brand-yellow selection, the activity
  /// dot and its rim switch to dark tones for contrast.
  final bool onSolidAccent;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final activityColor = switch (activity) {
      AgentConversationTabActivity.needsApproval => colors.warning,
      AgentConversationTabActivity.workFinished => colors.accent,
      AgentConversationTabActivity.none => null,
    };
    final resolvedTarget = target;
    final dotColor = onSolidAccent ? colors.textOnPrimary : activityColor;
    final dotBorderColor = onSolidAccent ? colors.primary : colors.surface;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: colors.surfaceLow,
                border: Border.all(color: colors.line.withAlpha(90), width: 1),
              ),
              child: Center(
                child: resolvedTarget == null
                    ? Icon(
                        Icons.smart_toy_outlined,
                        size: iconSize,
                        color: colors.textMuted,
                      )
                    : AgentBrandIcon(
                        target: resolvedTarget,
                        size: size,
                        iconSize: iconSize,
                        selected: false,
                        detected:
                            resolvedTarget.status == 'detected' ||
                            resolvedTarget.configured,
                      ),
              ),
            ),
          ),
          if (activityColor != null)
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                key: const Key('messaging-avatar-activity-dot'),
                width: size * 0.28,
                height: size * 0.28,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: dotColor,
                  border: Border.all(color: dotBorderColor, width: 2),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
