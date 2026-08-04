import 'package:flutter/material.dart';

import 'package:licoup/src/application/features/agents/orchestration/orchestration_policy_editor_models.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_orchestration_target_policy_fields.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

typedef CodeEngineeringRoleValueChanged =
    void Function(CodeEngineeringRoleSlot role, String value);

final class AgentOrchestrationCodeEngineeringPolicyCard
    extends StatelessWidget {
  const AgentOrchestrationCodeEngineeringPolicyCard({
    super.key,
    required this.policy,
    required this.targets,
    required this.onAgentChanged,
    required this.onModelChanged,
    required this.onReasoningEffortChanged,
  });

  final AgentOrchestrationPolicy policy;
  final List<TargetCandidate> targets;
  final CodeEngineeringRoleValueChanged onAgentChanged;
  final CodeEngineeringRoleValueChanged onModelChanged;
  final CodeEngineeringRoleValueChanged onReasoningEffortChanged;

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
              strings.codeEngineering,
              style: TextStyle(
                color: colors.text,
                fontWeight: FontWeight.w700,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 14),
            _RoleSection(
              title: 'Designer',
              description: strings.codeEngineeringDesignerDescription,
              children: [_fields(CodeEngineeringRoleSlot.designer)],
            ),
            Divider(height: 28, color: colors.line),
            _RoleSection(
              title: 'Worker',
              description: strings.codeEngineeringWorkerDescription,
              children: [
                _laneFields(
                  context,
                  strings.backendLane,
                  CodeEngineeringRoleSlot.backendWorker,
                ),
                const SizedBox(height: 12),
                _laneFields(
                  context,
                  strings.frontendLane,
                  CodeEngineeringRoleSlot.frontendWorker,
                ),
              ],
            ),
            Divider(height: 28, color: colors.line),
            _RoleSection(
              title: 'Reviewer',
              description: strings.codeEngineeringReviewerDescription,
              children: [
                _laneFields(
                  context,
                  strings.backendLane,
                  CodeEngineeringRoleSlot.backendReviewer,
                ),
                const SizedBox(height: 12),
                _laneFields(
                  context,
                  strings.frontendLane,
                  CodeEngineeringRoleSlot.frontendReviewer,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _laneFields(
    BuildContext context,
    String laneLabel,
    CodeEngineeringRoleSlot role,
  ) {
    final colors = context.licoColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          laneLabel,
          style: TextStyle(
            color: colors.textMuted,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        _fields(role),
      ],
    );
  }

  Widget _fields(CodeEngineeringRoleSlot role) {
    final assignment = policy.assignmentFor(role);
    return AgentOrchestrationTargetPolicyFields(
      keyPrefix: 'agent-orchestration-code-${role.configKey}',
      agentId: assignment.agentId,
      modelName: assignment.modelName,
      reasoningEffort: assignment.reasoningEffort,
      targets: targets,
      onAgentChanged: (value) => onAgentChanged(role, value),
      onModelChanged: (value) => onModelChanged(role, value),
      onReasoningEffortChanged: (value) =>
          onReasoningEffortChanged(role, value),
    );
  }
}

final class _RoleSection extends StatelessWidget {
  const _RoleSection({
    required this.title,
    required this.description,
    required this.children,
  });

  final String title;
  final String description;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            color: colors.text,
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          description,
          style: TextStyle(color: colors.textMuted, fontSize: 11),
        ),
        const SizedBox(height: 10),
        ...children,
      ],
    );
  }
}
