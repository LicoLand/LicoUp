import 'package:flutter/material.dart';

import 'package:licoup/src/application/features/agents/orchestration/orchestration_policy_editor_models.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_orchestration_target_policy_fields.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

final class AgentOrchestrationCommanderPolicyCard extends StatelessWidget {
  const AgentOrchestrationCommanderPolicyCard({
    super.key,
    required this.policy,
    required this.targets,
    required this.onAgentChanged,
    required this.onModelChanged,
    required this.onReasoningEffortChanged,
  });

  final AgentOrchestrationPolicy policy;
  final List<TargetCandidate> targets;
  final ValueChanged<String> onAgentChanged;
  final ValueChanged<String> onModelChanged;
  final ValueChanged<String> onReasoningEffortChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceLow,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.line),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              strings.commander,
              style: TextStyle(
                color: colors.text,
                fontWeight: FontWeight.w700,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 12),
            AgentOrchestrationTargetPolicyFields(
              keyPrefix: 'agent-orchestration-commander',
              agentId: policy.commanderAgentId,
              modelName: policy.commanderModelName,
              reasoningEffort: policy.commanderReasoningEffort,
              targets: targets,
              onAgentChanged: onAgentChanged,
              onModelChanged: onModelChanged,
              onReasoningEffortChanged: onReasoningEffortChanged,
            ),
          ],
        ),
      ),
    );
  }
}
