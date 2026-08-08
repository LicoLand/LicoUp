import 'package:flutter/material.dart';

import 'package:licoup/src/application/features/agents/orchestration/orchestration_target_catalog.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_display_names.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/apple_popup_select.dart';

final class AgentOrchestrationTargetPolicyFields extends StatelessWidget {
  const AgentOrchestrationTargetPolicyFields({
    super.key,
    required this.keyPrefix,
    required this.agentId,
    required this.modelName,
    required this.reasoningEffort,
    required this.targets,
    required this.onAgentChanged,
    required this.onModelChanged,
    required this.onReasoningEffortChanged,
  });

  final String keyPrefix;
  final String agentId;
  final String modelName;
  final String reasoningEffort;
  final List<TargetCandidate> targets;
  final ValueChanged<String> onAgentChanged;
  final ValueChanged<String> onModelChanged;
  final ValueChanged<String> onReasoningEffortChanged;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final selectedTarget = _selectedTarget();
    final models = selectedTarget == null
        ? const <String>[]
        : agentOrchestrationCommanderModels(selectedTarget);
    final selectedModel = models.contains(modelName) ? modelName : null;
    final reasoningEfforts = selectedTarget == null || selectedModel == null
        ? const <String>[]
        : agentOrchestrationReasoningEffortsForModel(
            selectedTarget,
            selectedModel,
          );
    final selectedReasoningEffort = reasoningEfforts.contains(reasoningEffort)
        ? reasoningEffort
        : reasoningEfforts.isEmpty
        ? null
        : reasoningEfforts.first;

    return Row(
      children: [
        Expanded(
          child: ApplePopupSelectField<String>(
            key: Key('$keyPrefix-agent'),
            label: strings.agentClient,
            value: selectedTarget?.target,
            options: [
              for (final target in targets)
                ApplePopupSelectOption(
                  value: target.target,
                  label: agentConversationTargetDisplayName(target),
                ),
            ],
            onChanged: onAgentChanged,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: ApplePopupSelectField<String>(
            key: Key('$keyPrefix-model'),
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
              key: Key('$keyPrefix-reasoning'),
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
    );
  }

  TargetCandidate? _selectedTarget() {
    final selected = agentId.trim();
    for (final target in targets) {
      if (target.target == selected) return target;
    }
    return targets.isEmpty ? null : targets.first;
  }
}
