import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/platform/agents/group_conversation_store.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_agent_avatar.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/tokens/messaging_desktop_tokens.dart';

/// Icon-only agent roster under the Lico group conversation title capsule.
/// Human/"You" entries are omitted — only Flywheel agent peers are shown.
class MessagingGroupRoster extends StatelessWidget {
  const MessagingGroupRoster({
    super.key,
    required this.participants,
    required this.targetsByAgentId,
  });

  final List<GroupParticipant> participants;
  final Map<String, TargetCandidate> targetsByAgentId;

  @override
  Widget build(BuildContext context) {
    final agents = [
      for (final participant in participants)
        if (participant.kind == GroupParticipantKind.agent) participant,
    ];
    if (agents.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        MessagingDesktopMetrics.conversationHeaderCapsuleInsetH,
        0,
        MessagingDesktopMetrics.conversationHeaderCapsuleInsetH,
        MessagingDesktopMetrics.conversationHeaderCapsuleInsetV,
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < agents.length; i++) ...[
                if (i > 0) const SizedBox(width: 6),
                Tooltip(
                  message: agents[i].displayName,
                  waitDuration: const Duration(milliseconds: 400),
                  child: MessagingAgentAvatar(
                    target: targetsByAgentId[agents[i].agentId ?? ''],
                    size: 22,
                    iconSize: 12,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
