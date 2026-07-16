import 'package:flutter/material.dart';

import 'package:flutter_client/src/application/controller/client_controller.dart';
import 'package:flutter_client/src/contracts/agent_orchestration_policy.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/agent_orchestration_commander_policy_card.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/agent_orchestration_model_library_policy_card.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/agent_orchestration_rename_policy_dialog.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_client/src/frontend/shared/ui/apple_popup_select.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';

final class AgentOrchestrationPolicyDialog extends StatefulWidget {
  const AgentOrchestrationPolicyDialog({super.key, required this.controller});

  final ClientController controller;

  @override
  State<AgentOrchestrationPolicyDialog> createState() =>
      _AgentOrchestrationPolicyDialogState();
}

final class _AgentOrchestrationPolicyDialogState
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
    final commanderModel = _commanderModelOrDefault(
      commanderAgentId,
      policy.commanderModelName,
    );
    return policy.copyWith(
      commanderAgentId: commanderAgentId,
      commanderModelName: commanderModel,
      commanderReasoningEffort: _commanderReasoningOrDefault(
        commanderAgentId,
        commanderModel,
        policy.commanderReasoningEffort,
      ),
    );
  }

  String _commanderModelOrDefault(String commanderAgentId, String modelName) {
    final models = _modelsForCommanderAgent(commanderAgentId);
    final normalized = modelName.trim();
    if (models.isEmpty) return normalized;
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
    if (efforts.isEmpty) return '';
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
    if (policy == null || policy.id == _policy.id) return;
    setState(() {
      _policy = _policyWithCommanderDefaults(policy!);
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
      final next = _modelLibrary.toList(growable: true);
      if (!next.any((item) => item.key == entry.key)) next.add(entry);
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
      builder: (context) =>
          AgentOrchestrationRenamePolicyDialog(initialName: initialName),
    );
    if (name == null) return;
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
                  AgentOrchestrationCommanderPolicyCard(
                    policy: _policy,
                    targets: agentOrchestrationCommanderTargets(
                      widget.controller.orchestrationAvailableTargets,
                    ),
                    onAgentChanged: _setCommanderAgent,
                    onModelChanged: _setCommanderModel,
                    onReasoningEffortChanged: _setCommanderReasoningEffort,
                  ),
                  const SizedBox(height: 12),
                  AgentOrchestrationModelLibraryPolicyCard(
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

final class _DialogPolicySelect extends StatelessWidget {
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
