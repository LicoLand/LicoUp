import 'package:flutter/material.dart';

import 'package:flutter_client/src/application/features/agents/orchestration/orchestration_policy_editor_models.dart';
import 'package:flutter_client/src/application/features/agents/orchestration/orchestration_target_catalog.dart';
import 'package:flutter_client/src/contracts/target_candidate.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/agent_conversation_display_names.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_client/src/frontend/shared/ui/agent_brand_icon.dart';
import 'package:flutter_client/src/frontend/shared/ui/apple_popup_select.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';

final class AgentOrchestrationModelLibraryPolicyCard extends StatefulWidget {
  const AgentOrchestrationModelLibraryPolicyCard({
    super.key,
    required this.entries,
    required this.targets,
    required this.onAdd,
    required this.onRemove,
  });

  final List<AgentModelLibraryEntry> entries;
  final List<TargetCandidate> targets;
  final ValueChanged<AgentModelLibraryEntry> onAdd;
  final ValueChanged<AgentModelLibraryEntry> onRemove;

  @override
  State<AgentOrchestrationModelLibraryPolicyCard> createState() =>
      _AgentOrchestrationModelLibraryPolicyCardState();
}

final class _AgentOrchestrationModelLibraryPolicyCardState
    extends State<AgentOrchestrationModelLibraryPolicyCard> {
  String _agentId = '';
  String _modelName = '';
  String _reasoningEffort = '';

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final selectedKeys = {for (final entry in widget.entries) entry.key};
    final targetsById = {
      for (final target in widget.targets) target.target: target,
    };
    final selectedTarget = _selectedTarget();
    final models = selectedTarget == null
        ? const <String>[]
        : agentOrchestrationCommanderModels(selectedTarget);
    final selectedAgentId = selectedTarget?.target ?? '';
    final selectedModel = models.contains(_modelName)
        ? _modelName
        : models.isEmpty
        ? ''
        : models.first;
    final reasoningEfforts = selectedTarget == null
        ? const <String>[]
        : agentOrchestrationReasoningEffortsForModel(
            selectedTarget,
            selectedModel,
          );
    final selectedReasoningEffort = reasoningEfforts.contains(_reasoningEffort)
        ? _reasoningEffort
        : reasoningEfforts.isEmpty
        ? ''
        : reasoningEfforts.first;
    final draft = AgentModelLibraryEntry(
      agentId: selectedAgentId,
      modelName: selectedModel,
      reasoningEffort: selectedReasoningEffort,
    );
    final canAdd = draft.configured && !selectedKeys.contains(draft.key);
    return DecoratedBox(
      key: const Key('agent-orchestration-model-library'),
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
              strings.modelLibrary,
              style: TextStyle(
                color: colors.text,
                fontWeight: FontWeight.w700,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: ApplePopupSelectField<String>(
                    key: const Key('agent-orchestration-model-library-agent'),
                    label: strings.agentClient,
                    value: selectedAgentId.isEmpty ? null : selectedAgentId,
                    options: [
                      for (final target in widget.targets)
                        ApplePopupSelectOption(
                          value: target.target,
                          label: agentConversationTargetDisplayName(target),
                        ),
                    ],
                    onChanged: _setAgent,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ApplePopupSelectField<String>(
                    key: const Key('agent-orchestration-model-library-model'),
                    label: strings.model,
                    value: selectedModel.isEmpty ? null : selectedModel,
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
                    onChanged: models.isEmpty ? null : _setModel,
                    enabled: models.isNotEmpty,
                  ),
                ),
                if (reasoningEfforts.isNotEmpty) ...[
                  const SizedBox(width: 10),
                  Expanded(
                    child: ApplePopupSelectField<String>(
                      key: const Key(
                        'agent-orchestration-model-library-reasoning',
                      ),
                      label: strings.reasoningEffort,
                      value: selectedReasoningEffort.isEmpty
                          ? null
                          : selectedReasoningEffort,
                      options: [
                        for (final effort in reasoningEfforts)
                          ApplePopupSelectOption(value: effort, label: effort),
                      ],
                      onChanged: (value) {
                        setState(() => _reasoningEffort = value);
                      },
                    ),
                  ),
                ],
                const SizedBox(width: 10),
                Padding(
                  padding: const EdgeInsets.only(top: 18),
                  child: FilledButton.icon(
                    key: const Key('agent-orchestration-model-library-add'),
                    onPressed: canAdd ? () => widget.onAdd(draft) : null,
                    icon: const Icon(Icons.add, size: 18),
                    label: Text(strings.add),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (widget.entries.isEmpty)
              Text(
                strings.noModelLibraryEntries,
                style: TextStyle(color: colors.textMuted, fontSize: 13),
              )
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final entry in widget.entries)
                    _ModelLibraryChip(
                      key: Key(
                        'agent-orchestration-model-library-${_entryDomKey(entry)}',
                      ),
                      entry: entry,
                      target: targetsById[entry.agentId],
                      onDeleted: () => widget.onRemove(entry),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  TargetCandidate? _selectedTarget() {
    for (final target in widget.targets) {
      if (target.target == _agentId) return target;
    }
    return widget.targets.isEmpty ? null : widget.targets.first;
  }

  void _setAgent(String agentId) {
    TargetCandidate? target;
    for (final candidate in widget.targets) {
      if (candidate.target == agentId) {
        target = candidate;
        break;
      }
    }
    final models = target == null
        ? const <String>[]
        : agentOrchestrationCommanderModels(target);
    final firstModel = models.isEmpty ? '' : models.first;
    final efforts = target == null
        ? const <String>[]
        : agentOrchestrationReasoningEffortsForModel(target, firstModel);
    setState(() {
      _agentId = agentId;
      _modelName = firstModel;
      _reasoningEffort = efforts.isEmpty ? '' : efforts.first;
    });
  }

  void _setModel(String modelName) {
    final target = _selectedTarget();
    final efforts = target == null
        ? const <String>[]
        : agentOrchestrationReasoningEffortsForModel(target, modelName);
    setState(() {
      _modelName = modelName;
      _reasoningEffort = efforts.isEmpty ? '' : efforts.first;
    });
  }
}

final class _ModelLibraryChip extends StatelessWidget {
  const _ModelLibraryChip({
    super.key,
    required this.entry,
    required this.target,
    required this.onDeleted,
  });

  final AgentModelLibraryEntry entry;
  final TargetCandidate? target;
  final VoidCallback onDeleted;

  @override
  Widget build(BuildContext context) {
    final label = [
      target?.label ?? entry.agentId,
      target == null
          ? entry.modelName
          : agentOrchestrationModelDisplayName(target!, entry.modelName),
      if (entry.reasoningEffort.trim().isNotEmpty) entry.reasoningEffort.trim(),
    ].join(' · ');
    return InputChip(
      onDeleted: onDeleted,
      avatar: target == null
          ? const Icon(Icons.memory_outlined, size: 18)
          : AgentBrandIcon(target: target!, size: 20, iconSize: 15),
      label: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 280),
        child: Text(label, overflow: TextOverflow.ellipsis),
      ),
    );
  }
}

String _entryDomKey(AgentModelLibraryEntry entry) {
  final effort = entry.reasoningEffort.trim().isEmpty
      ? 'auto'
      : entry.reasoningEffort.trim();
  return '${entry.agentId}-${entry.modelName}-$effort'
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
}
