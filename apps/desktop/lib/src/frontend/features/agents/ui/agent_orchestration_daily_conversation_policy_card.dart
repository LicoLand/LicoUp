import 'package:flutter/material.dart';

import 'package:licoup/src/application/features/agents/orchestration/orchestration_policy_editor_models.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_orchestration_multi_capsule_section.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';

/// Adaptive Flywheel Daily Conversation multi-capsule picker.
final class AgentOrchestrationDailyConversationPolicyCard
    extends StatelessWidget {
  const AgentOrchestrationDailyConversationPolicyCard({
    super.key,
    required this.assignments,
    required this.targets,
    required this.onChanged,
  });

  final List<DailyConversationAgentAssignment> assignments;
  final List<TargetCandidate> targets;
  final ValueChanged<List<DailyConversationAgentAssignment>> onChanged;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    return AgentOrchestrationMultiCapsuleSection(
      title: strings.dailyConversation,
      keyPrefix: 'agent-orchestration-daily-conversation',
      idPrefix: 'dc',
      showFast: true,
      highlightFirstAsCurrentConversation: true,
      assignments: assignments,
      targets: targets,
      onChanged: onChanged,
    );
  }
}
