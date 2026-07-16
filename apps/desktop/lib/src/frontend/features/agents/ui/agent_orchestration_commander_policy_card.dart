import 'package:flutter/material.dart';

import 'package:flutter_client/src/contracts/agent_orchestration_policy.dart';
import 'package:flutter_client/src/contracts/target_candidate.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_client/src/frontend/shared/ui/apple_popup_select.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';

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
    final selectedTarget = _selectedTarget();
    final models = selectedTarget == null
        ? const <String>[]
        : agentOrchestrationCommanderModels(selectedTarget);
    final selectedModel = models.contains(policy.commanderModelName)
        ? policy.commanderModelName
        : null;
    final reasoningEfforts = selectedTarget == null || selectedModel == null
        ? const <String>[]
        : agentOrchestrationReasoningEffortsForModel(
            selectedTarget,
            selectedModel,
          );
    final selectedReasoningEffort =
        reasoningEfforts.contains(policy.commanderReasoningEffort)
        ? policy.commanderReasoningEffort
        : reasoningEfforts.isEmpty
        ? null
        : reasoningEfforts.first;
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
            Row(
              children: [
                Expanded(
                  child: ApplePopupSelectField<String>(
                    key: const Key('agent-orchestration-commander-agent'),
                    label: strings.agentClient,
                    value: selectedTarget?.target,
                    options: [
                      for (final target in targets)
                        ApplePopupSelectOption(
                          value: target.target,
                          label: target.label,
                        ),
                    ],
                    onChanged: onAgentChanged,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ApplePopupSelectField<String>(
                    key: const Key('agent-orchestration-commander-model'),
                    label: strings.model,
                    value: selectedModel,
                    hint: models.isEmpty ? strings.noModelsFound : null,
                    options: [
                      for (final model in models)
                        ApplePopupSelectOption(
                          value: model,
                          label: selectedTarget == null
                              ? model
                              : agentOrchestrationModelDisplayName(
                                  selectedTarget,
                                  model,
                                ),
                        ),
                    ],
                    onChanged: models.isEmpty ? null : onModelChanged,
                    enabled: models.isNotEmpty,
                  ),
                ),
                if (reasoningEfforts.isNotEmpty) ...[
                  const SizedBox(width: 12),
                  Expanded(
                    child: ApplePopupSelectField<String>(
                      key: const Key('agent-orchestration-commander-reasoning'),
                      label: strings.reasoningEffort,
                      value: selectedReasoningEffort,
                      options: [
                        for (final effort in reasoningEfforts)
                          ApplePopupSelectOption(value: effort, label: effort),
                      ],
                      onChanged: onReasoningEffortChanged,
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  TargetCandidate? _selectedTarget() {
    final selected = policy.commanderAgentId.trim();
    for (final target in targets) {
      if (target.target == selected) return target;
    }
    return targets.isEmpty ? null : targets.first;
  }
}
