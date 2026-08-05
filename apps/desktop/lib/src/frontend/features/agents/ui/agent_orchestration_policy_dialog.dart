import 'package:flutter/material.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/application/features/agents/orchestration/orchestration_policy_editor_models.dart';
import 'package:licoup/src/application/features/agents/orchestration/orchestration_target_catalog.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_orchestration_code_engineering_policy_card.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_orchestration_daily_conversation_policy_card.dart';
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
    _policy = _policyWithDefaults(
      widget.controller.effectiveAgentOrchestrationPolicy,
    );
  }

  AgentOrchestrationPolicy _policyWithDefaults(
    AgentOrchestrationPolicy policy,
  ) {
    final seeded = policy.withDailyConversationSeededFromCommander();
    final roleAssignments =
        <CodeEngineeringRoleSlot, AgentOrchestrationRoleAssignment>{
          for (final role in CodeEngineeringRoleSlot.values)
            role: _roleAssignmentWithDefaults(seeded.assignmentFor(role)),
        };
    return seeded
        .copyWith(codeEngineeringRoles: roleAssignments)
        .withCommanderSyncedFromDailyConversation();
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
    final modelName = _modelOrDefault(agentId, assignment.modelName);
    return AgentOrchestrationRoleAssignment(
      agentId: agentId,
      modelName: modelName,
      reasoningEffort: _reasoningOrDefault(
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

  String _modelOrDefault(String agentId, String modelName) {
    final models = _modelsForAgent(agentId);
    final normalized = modelName.trim();
    if (models.isEmpty) return normalized;
    return models.contains(normalized) ? normalized : models.first;
  }

  List<String> _modelsForAgent(String agentId) {
    for (final target in widget.controller.orchestrationAvailableTargets) {
      if (target.target == agentId) {
        return agentOrchestrationCommanderModels(target);
      }
    }
    return const [];
  }

  String _reasoningOrDefault(
    String agentId,
    String modelName,
    String reasoningEffort,
  ) {
    final efforts = _reasoningEffortsForModel(agentId, modelName);
    final normalized = reasoningEffort.trim();
    if (efforts.isEmpty) return '';
    return efforts.contains(normalized) ? normalized : efforts.first;
  }

  List<String> _reasoningEffortsForModel(String agentId, String modelName) {
    for (final target in widget.controller.orchestrationAvailableTargets) {
      if (target.target == agentId) {
        return agentOrchestrationReasoningEffortsForModel(target, modelName);
      }
    }
    return const [];
  }

  void _setDailyConversationAgents(
    List<DailyConversationAgentAssignment> agents,
  ) {
    setState(() {
      _policy = _policy
          .copyWith(dailyConversationAgents: agents)
          .withCommanderSyncedFromDailyConversation();
    });
  }

  void _setCodeEngineeringAgent(CodeEngineeringRoleSlot role, String agentId) {
    final modelName = _modelOrDefault(agentId, '');
    _setCodeEngineeringAssignment(
      role,
      AgentOrchestrationRoleAssignment(
        agentId: agentId,
        modelName: modelName,
        reasoningEffort: _reasoningOrDefault(agentId, modelName, ''),
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
        reasoningEffort: _reasoningOrDefault(assignment.agentId, modelName, ''),
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
    Navigator.of(
      context,
    ).pop(_policy.withCommanderSyncedFromDailyConversation());
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
                  AgentOrchestrationDailyConversationPolicyCard(
                    assignments: _policy.dailyConversationAgents,
                    targets: agentOrchestrationCommanderTargets(
                      widget.controller.orchestrationAvailableTargets,
                    ),
                    onChanged: _setDailyConversationAgents,
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
