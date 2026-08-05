import 'package:flutter/material.dart';

import 'package:licoup/src/application/features/agents/orchestration/orchestration_policy_editor_models.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_orchestration_multi_capsule_section.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';

final class AgentOrchestrationCodeEngineeringPolicyCard
    extends StatelessWidget {
  const AgentOrchestrationCodeEngineeringPolicyCard({
    super.key,
    required this.policy,
    required this.targets,
    required this.onDesignerChanged,
    required this.onWorkerChanged,
    required this.onReviewerChanged,
  });

  final AgentOrchestrationPolicy policy;
  final List<TargetCandidate> targets;
  final ValueChanged<List<DailyConversationAgentAssignment>> onDesignerChanged;
  final ValueChanged<List<DailyConversationAgentAssignment>> onWorkerChanged;
  final ValueChanged<List<DailyConversationAgentAssignment>> onReviewerChanged;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AgentOrchestrationMultiCapsuleSection(
          title: strings.codeEngineeringDesigner,
          keyPrefix: 'agent-orchestration-code-designer',
          idPrefix: 'ce-designer',
          assignments: policy.designerAgents,
          targets: targets,
          onChanged: onDesignerChanged,
        ),
        const SizedBox(height: 16),
        AgentOrchestrationMultiCapsuleSection(
          title: strings.codeEngineeringWorker,
          keyPrefix: 'agent-orchestration-code-worker',
          idPrefix: 'ce-worker',
          assignments: policy.workerAgents,
          targets: targets,
          onChanged: onWorkerChanged,
        ),
        const SizedBox(height: 16),
        AgentOrchestrationMultiCapsuleSection(
          title: strings.codeEngineeringReviewer,
          keyPrefix: 'agent-orchestration-code-reviewer',
          idPrefix: 'ce-reviewer',
          assignments: policy.reviewerAgents,
          targets: targets,
          onChanged: onReviewerChanged,
        ),
      ],
    );
  }
}
