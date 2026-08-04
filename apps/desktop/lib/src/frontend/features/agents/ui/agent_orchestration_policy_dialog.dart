import 'package:flutter/material.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/application/features/agents/orchestration/orchestration_policy_editor_models.dart';
import 'package:licoup/src/application/features/agents/orchestration/orchestration_target_catalog.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_orchestration_code_engineering_policy_card.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_orchestration_commander_policy_card.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

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

  @override
  void initState() {
    super.initState();
    _policy = _policyWithCommanderDefaults(
      widget.controller.effectiveAgentOrchestrationPolicy,
    );
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
    final roleAssignments =
        <CodeEngineeringRoleSlot, AgentOrchestrationRoleAssignment>{
          for (final role in CodeEngineeringRoleSlot.values)
            role: _roleAssignmentWithDefaults(policy.assignmentFor(role)),
        };
    return policy.copyWith(
      commanderAgentId: commanderAgentId,
      commanderModelName: commanderModel,
      commanderReasoningEffort: _commanderReasoningOrDefault(
        commanderAgentId,
        commanderModel,
        policy.commanderReasoningEffort,
      ),
      codeEngineeringRoles: roleAssignments,
    );
  }

  AgentOrchestrationRoleAssignment _roleAssignmentWithDefaults(
    AgentOrchestrationRoleAssignment assignment,
  ) {
    var agentId = assignment.agentId.trim();
    if (!_modelsByAgentContains(agentId)) {
      agentId = defaultAgentOrchestrationCommanderAgentId(
        widget.controller.orchestrationAvailableTargets,
      );
    }
    final modelName = _commanderModelOrDefault(agentId, assignment.modelName);
    return AgentOrchestrationRoleAssignment(
      agentId: agentId,
      modelName: modelName,
      reasoningEffort: _commanderReasoningOrDefault(
        agentId,
        modelName,
        assignment.reasoningEffort,
      ),
    );
  }

  bool _modelsByAgentContains(String agentId) {
    if (agentId.isEmpty) return false;
    return widget.controller.orchestrationAvailableTargets.any(
      (target) => target.target == agentId,
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

  void _setCodeEngineeringAgent(CodeEngineeringRoleSlot role, String agentId) {
    final modelName = _commanderModelOrDefault(agentId, '');
    _setCodeEngineeringAssignment(
      role,
      AgentOrchestrationRoleAssignment(
        agentId: agentId,
        modelName: modelName,
        reasoningEffort: _commanderReasoningOrDefault(agentId, modelName, ''),
      ),
    );
  }

  void _setCodeEngineeringModel(
    CodeEngineeringRoleSlot role,
    String modelName,
  ) {
    final assignment = _policy.assignmentFor(role);
    _setCodeEngineeringAssignment(
      role,
      assignment.copyWith(
        modelName: modelName,
        reasoningEffort: _commanderReasoningOrDefault(
          assignment.agentId,
          modelName,
          '',
        ),
      ),
    );
  }

  void _setCodeEngineeringReasoningEffort(
    CodeEngineeringRoleSlot role,
    String reasoningEffort,
  ) {
    _setCodeEngineeringAssignment(
      role,
      _policy.assignmentFor(role).copyWith(reasoningEffort: reasoningEffort),
    );
  }

  void _setCodeEngineeringAssignment(
    CodeEngineeringRoleSlot role,
    AgentOrchestrationRoleAssignment assignment,
  ) {
    setState(() {
      _policy = _policy.copyWith(
        codeEngineeringRoles: {
          ..._policy.codeEngineeringRoles,
          role: assignment,
        },
      );
    });
  }

  void _save() {
    Navigator.of(context).pop(_policy);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
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
                  Icon(Icons.hub_outlined, color: colors.textSecondary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      strings.editMainAgent,
                      style: TextStyle(
                        color: colors.text,
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
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
                key: const Key('main-agent-settings'),
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
                  const SizedBox(height: 14),
                  AgentOrchestrationCodeEngineeringPolicyCard(
                    policy: _policy,
                    targets: agentOrchestrationCommanderTargets(
                      widget.controller.orchestrationAvailableTargets,
                    ),
                    onAgentChanged: _setCodeEngineeringAgent,
                    onModelChanged: _setCodeEngineeringModel,
                    onReasoningEffortChanged:
                        _setCodeEngineeringReasoningEffort,
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
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(strings.cancel),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    key: const Key('main-agent-save'),
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
