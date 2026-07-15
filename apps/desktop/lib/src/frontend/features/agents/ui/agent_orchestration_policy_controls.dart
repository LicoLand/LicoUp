import 'package:flutter/material.dart';

import 'package:flutter_client/src/application/controller/client_controller.dart';
import 'package:flutter_client/src/contracts/agent_orchestration_policy.dart';
import 'package:flutter_client/src/contracts/target_candidate.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_client/src/frontend/shared/ui/agent_brand_icon.dart';
import 'package:flutter_client/src/frontend/shared/ui/apple_popup_select.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';

class AgentOrchestrationPolicyHeaderControls extends StatelessWidget {
  const AgentOrchestrationPolicyHeaderControls({
    super.key,
    required this.controller,
  });

  final ClientController controller;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final policy = controller.effectiveAgentOrchestrationPolicy;
    final policies = controller.agentOrchestrationPolicies;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 240, minWidth: 176),
          child: ApplePopupSelect<String>(
            key: const Key('agent-orchestration-policy-select'),
            value: policy.id,
            isExpanded: true,
            warningBorder: !policy.configured,
            options: [
              for (final item in policies)
                ApplePopupSelectOption(
                  value: item.id,
                  label: controller.agentOrchestrationPolicyDisplayLabel(item),
                ),
            ],
            onChanged: controller.selectAgentOrchestrationPolicy,
          ),
        ),
        const SizedBox(width: 6),
        IconButton(
          key: const Key('agent-orchestration-policy-edit'),
          tooltip: strings.editPolicy,
          onPressed: () =>
              showAgentOrchestrationPolicyEditor(context, controller),
          color: colors.primary,
          hoverColor: Color.lerp(colors.surface, colors.primary, 0.12),
          style: IconButton.styleFrom(
            fixedSize: const Size(36, 36),
            minimumSize: const Size(36, 36),
            padding: EdgeInsets.zero,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          icon: const Icon(Icons.edit_outlined, size: 18),
        ),
      ],
    );
  }
}

Future<void> showAgentOrchestrationPolicyEditor(
  BuildContext context,
  ClientController controller,
) async {
  final policy = await showDialog<AgentOrchestrationPolicy>(
    context: context,
    builder: (_) => AgentOrchestrationPolicyDialog(controller: controller),
  );
  if (policy == null || !context.mounted) {
    return;
  }
  await controller.saveAgentOrchestrationPolicy(policy);
}

class AgentOrchestrationPolicyDialog extends StatefulWidget {
  const AgentOrchestrationPolicyDialog({super.key, required this.controller});

  final ClientController controller;

  @override
  State<AgentOrchestrationPolicyDialog> createState() =>
      _AgentOrchestrationPolicyDialogState();
}

class _AgentOrchestrationPolicyDialogState
    extends State<AgentOrchestrationPolicyDialog> {
  late AgentOrchestrationPolicy _policy;
  late List<AgentModelLibraryEntry> _modelLibrary;

  @override
  void initState() {
    super.initState();
    _policy = _policyWithCommanderDefaults(
      widget.controller.effectiveAgentOrchestrationPolicy,
    );
    _modelLibrary = _policy.modelLibrary.toList(growable: true);
  }

  AgentOrchestrationPolicy _policyWithCommanderDefaults(
    AgentOrchestrationPolicy policy,
  ) {
    var commanderAgentId = policy.commanderAgentId.trim();
    if (commanderAgentId.isEmpty) {
      commanderAgentId = defaultAgentOrchestrationCommanderAgentId(
        widget.controller.scannedTargets,
      );
    }
    return policy.copyWith(
      commanderAgentId: commanderAgentId,
      commanderModelName: _commanderModelOrDefault(
        commanderAgentId,
        policy.commanderModelName,
      ),
      commanderReasoningEffort: _commanderReasoningOrDefault(
        commanderAgentId,
        _commanderModelOrDefault(commanderAgentId, policy.commanderModelName),
        policy.commanderReasoningEffort,
      ),
    );
  }

  String _commanderModelOrDefault(String commanderAgentId, String modelName) {
    final models = _modelsForCommanderAgent(commanderAgentId);
    final normalized = modelName.trim();
    if (models.isEmpty) {
      return normalized;
    }
    return models.contains(normalized) ? normalized : models.first;
  }

  List<String> _modelsForCommanderAgent(String agentId) {
    for (final target in widget.controller.orchestrationAvailableTargets) {
      if (target.target == agentId) {
        return agentOrchestrationCommanderModels(target);
      }
    }
    return const [];
  }

  String _commanderReasoningOrDefault(
    String commanderAgentId,
    String modelName,
    String reasoningEffort,
  ) {
    final efforts = _reasoningEffortsForCommanderModel(
      commanderAgentId,
      modelName,
    );
    final normalized = reasoningEffort.trim();
    if (efforts.isEmpty) {
      return '';
    }
    return efforts.contains(normalized) ? normalized : efforts.first;
  }

  List<String> _reasoningEffortsForCommanderModel(
    String agentId,
    String modelName,
  ) {
    for (final target in widget.controller.orchestrationAvailableTargets) {
      if (target.target == agentId) {
        return agentOrchestrationReasoningEffortsForModel(target, modelName);
      }
    }
    return const [];
  }

  void _selectPolicy(String policyId) {
    AgentOrchestrationPolicy? policy;
    for (final item in widget.controller.agentOrchestrationPolicies) {
      if (item.id == policyId) {
        policy = item;
        break;
      }
    }
    if (policy == null || policy.id == _policy.id) {
      return;
    }
    final selectedPolicy = policy;
    setState(() {
      _policy = _policyWithCommanderDefaults(selectedPolicy);
      _modelLibrary = _policy.modelLibrary.toList(growable: true);
    });
  }

  void _setCommanderAgent(String agentId) {
    final modelName = _commanderModelOrDefault(agentId, '');
    setState(() {
      _policy = _policy.copyWith(
        commanderAgentId: agentId,
        commanderModelName: modelName,
        commanderReasoningEffort: _commanderReasoningOrDefault(
          agentId,
          modelName,
          '',
        ),
      );
    });
  }

  void _setCommanderModel(String modelName) {
    setState(() {
      _policy = _policy.copyWith(
        commanderModelName: modelName,
        commanderReasoningEffort: _commanderReasoningOrDefault(
          _policy.commanderAgentId,
          modelName,
          '',
        ),
      );
    });
  }

  void _setCommanderReasoningEffort(String reasoningEffort) {
    setState(() {
      _policy = _policy.copyWith(commanderReasoningEffort: reasoningEffort);
    });
  }

  void _addModelLibraryEntry(AgentModelLibraryEntry entry) {
    setState(() {
      final selectedKey = entry.key;
      final next = _modelLibrary.toList(growable: true);
      if (!next.any((item) => item.key == selectedKey)) {
        next.add(entry);
      }
      _modelLibrary = next;
      _policy = _policy.copyWith(modelLibrary: List.unmodifiable(next));
    });
  }

  void _removeModelLibraryEntry(AgentModelLibraryEntry entry) {
    setState(() {
      final next = _modelLibrary
          .where((item) => item.key != entry.key)
          .toList(growable: false);
      _modelLibrary = next;
      _policy = _policy.copyWith(modelLibrary: List.unmodifiable(next));
    });
  }

  Future<void> _renamePolicy() async {
    final strings = LicoStrings.of(context);
    final initialName = _policy.label.trim().isEmpty
        ? strings.defaultPolicy
        : _policy.label.trim();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => _RenamePolicyDialog(initialName: initialName),
    );
    if (name == null) {
      return;
    }
    setState(() {
      _policy = _policy.copyWith(
        label: name.trim().isEmpty ? strings.defaultPolicy : name.trim(),
      );
    });
  }

  void _save() {
    final modelLibrary = normalizeAgentModelLibrary(
      widget.controller.scannedTargets,
      _modelLibrary,
    );
    Navigator.of(context).pop(_policy.copyWith(modelLibrary: modelLibrary));
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final policies = widget.controller.agentOrchestrationPolicies;
    return Dialog(
      backgroundColor: colors.surface,
      insetPadding: const EdgeInsets.symmetric(horizontal: 48, vertical: 36),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 780, maxHeight: 680),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 12, 12),
              child: Row(
                children: [
                  Icon(Icons.account_tree_outlined, color: colors.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _DialogPolicySelect(
                      policies: [
                        for (final policy in policies)
                          policy.id == _policy.id ? _policy : policy,
                      ],
                      value: _policy.id,
                      onChanged: _selectPolicy,
                    ),
                  ),
                  IconButton(
                    key: const Key('agent-orchestration-policy-rename'),
                    tooltip: strings.renamePolicy,
                    onPressed: _renamePolicy,
                    color: colors.primary,
                    icon: const Icon(Icons.drive_file_rename_outline, size: 18),
                  ),
                  IconButton(
                    tooltip: strings.close,
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, size: 18),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: colors.line),
            Expanded(
              child: ListView(
                key: const Key('agent-orchestration-policy-rule-list'),
                padding: const EdgeInsets.all(16),
                children: [
                  _CommanderPolicyCard(
                    policy: _policy,
                    targets: agentOrchestrationCommanderTargets(
                      widget.controller.orchestrationAvailableTargets,
                    ),
                    onAgentChanged: _setCommanderAgent,
                    onModelChanged: _setCommanderModel,
                    onReasoningEffortChanged: _setCommanderReasoningEffort,
                  ),
                  const SizedBox(height: 12),
                  _ModelLibraryPolicyCard(
                    entries: _modelLibrary,
                    targets: agentOrchestrationCommanderTargets(
                      widget.controller.orchestrationAvailableTargets,
                    ),
                    onAdd: _addModelLibraryEntry,
                    onRemove: _removeModelLibraryEntry,
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: colors.line),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
              child: Row(
                children: [
                  const Spacer(),
                  if (widget
                      .controller
                      .agentOrchestrationOpenCircuitAgentIds
                      .isNotEmpty) ...[
                    TextButton.icon(
                      key: const Key('agent-orchestration-reset-circuit'),
                      onPressed: widget
                          .controller
                          .resetAgentOrchestrationCircuitBreakers,
                      icon: const Icon(Icons.restart_alt_outlined, size: 18),
                      label: Text(strings.resetCircuitBreaker),
                    ),
                    const SizedBox(width: 8),
                  ],
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(strings.cancel),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    key: const Key('agent-orchestration-save-policy'),
                    onPressed: _save,
                    child: Text(strings.save),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DialogPolicySelect extends StatelessWidget {
  const _DialogPolicySelect({
    required this.policies,
    required this.value,
    required this.onChanged,
  });

  final List<AgentOrchestrationPolicy> policies;
  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 360),
      child: ApplePopupSelect<String>(
        key: const Key('agent-orchestration-dialog-policy-select'),
        value: value,
        isExpanded: true,
        emphasized: true,
        options: [
          for (final policy in policies)
            ApplePopupSelectOption(
              value: policy.id,
              label: policy.label.trim().isEmpty
                  ? strings.defaultPolicy
                  : policy.label.trim(),
            ),
        ],
        onChanged: onChanged,
      ),
    );
  }
}

class _RenamePolicyDialog extends StatefulWidget {
  const _RenamePolicyDialog({required this.initialName});

  final String initialName;

  @override
  State<_RenamePolicyDialog> createState() => _RenamePolicyDialogState();
}

class _RenamePolicyDialogState extends State<_RenamePolicyDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialName);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    Navigator.of(context).pop(_controller.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    return AlertDialog(
      backgroundColor: colors.surface,
      title: Text(strings.renamePolicy),
      content: TextField(
        key: const Key('agent-orchestration-policy-name-field'),
        controller: _controller,
        autofocus: true,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _submit(),
        decoration: InputDecoration(
          labelText: strings.policyName,
          isDense: true,
          filled: true,
          fillColor: colors.surfaceLow,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(strings.cancel),
        ),
        FilledButton(
          key: const Key('agent-orchestration-policy-rename-save'),
          onPressed: _submit,
          child: Text(strings.save),
        ),
      ],
    );
  }
}

class _CommanderPolicyCard extends StatelessWidget {
  const _CommanderPolicyCard({
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
      if (target.target == selected) {
        return target;
      }
    }
    return targets.isEmpty ? null : targets.first;
  }
}

class _ModelLibraryPolicyCard extends StatelessWidget {
  const _ModelLibraryPolicyCard({
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
  Widget build(BuildContext context) {
    return _ModelLibraryPolicyCardBody(
      entries: entries,
      targets: targets,
      onAdd: onAdd,
      onRemove: onRemove,
    );
  }
}

class _ModelLibraryPolicyCardBody extends StatefulWidget {
  const _ModelLibraryPolicyCardBody({
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
  State<_ModelLibraryPolicyCardBody> createState() =>
      _ModelLibraryPolicyCardBodyState();
}

class _ModelLibraryPolicyCardBodyState
    extends State<_ModelLibraryPolicyCardBody> {
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
                          label: target.label,
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
                        'agent-orchestration-model-library-${_modelLibraryEntryDomKey(entry)}',
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
      if (target.target == _agentId) {
        return target;
      }
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
    final reasoningEfforts = target == null
        ? const <String>[]
        : agentOrchestrationReasoningEffortsForModel(target, firstModel);
    setState(() {
      _agentId = agentId;
      _modelName = firstModel;
      _reasoningEffort = reasoningEfforts.isEmpty ? '' : reasoningEfforts.first;
    });
  }

  void _setModel(String modelName) {
    final target = _selectedTarget();
    final reasoningEfforts = target == null
        ? const <String>[]
        : agentOrchestrationReasoningEffortsForModel(target, modelName);
    setState(() {
      _modelName = modelName;
      _reasoningEffort = reasoningEfforts.isEmpty ? '' : reasoningEfforts.first;
    });
  }
}

class _ModelLibraryChip extends StatelessWidget {
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

String _modelLibraryEntryDomKey(AgentModelLibraryEntry entry) {
  final effort = entry.reasoningEffort.trim().isEmpty
      ? 'auto'
      : entry.reasoningEffort.trim();
  final raw = '${entry.agentId}-${entry.modelName}-$effort'.toLowerCase();
  return raw
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
}
