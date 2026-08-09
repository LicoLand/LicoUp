import 'package:flutter/material.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/application/features/agents/orchestration/orchestration_policy_editor_models.dart';
import 'package:licoup/src/application/features/agents/orchestration/orchestration_target_catalog.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_orchestration_code_engineering_policy_card.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_orchestration_daily_conversation_policy_card.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/lico_radius.dart';
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
    return seeded
        .copyWith(
          designerAgents: _seededRoleAgents(
            seeded.designerAgents,
            idPrefix: 'ce-designer',
          ),
          workerAgents: _seededRoleAgents(
            seeded.workerAgents,
            idPrefix: 'ce-worker',
          ),
          reviewerAgents: _seededRoleAgents(
            seeded.reviewerAgents,
            idPrefix: 'ce-reviewer',
          ),
        )
        .withCommanderSyncedFromDailyConversation();
  }

  List<DailyConversationAgentAssignment> _seededRoleAgents(
    List<DailyConversationAgentAssignment> existing, {
    required String idPrefix,
  }) {
    if (existing.any((assignment) => assignment.configured)) {
      return [
        for (final assignment in existing)
          if (assignment.configured) _capsuleWithDefaults(assignment, idPrefix),
      ];
    }
    final seed = _defaultCapsule(idPrefix);
    return seed == null ? const [] : [seed];
  }

  DailyConversationAgentAssignment? _defaultCapsule(String idPrefix) {
    final agentId = defaultAgentOrchestrationCommanderAgentId(
      widget.controller.orchestrationAvailableTargets,
    );
    if (agentId.isEmpty) return null;
    final modelName = _modelOrDefault(agentId, '');
    return DailyConversationAgentAssignment(
      id: '$idPrefix-$agentId-0',
      agentId: agentId,
      modelName: modelName,
      reasoningEffort: _reasoningOrDefault(agentId, modelName, ''),
    );
  }

  DailyConversationAgentAssignment _capsuleWithDefaults(
    DailyConversationAgentAssignment assignment,
    String idPrefix,
  ) {
    var agentId = assignment.agentId.trim();
    if (!_modelsByAgentContains(agentId)) {
      agentId = defaultAgentOrchestrationCommanderAgentId(
        widget.controller.orchestrationAvailableTargets,
      );
    }
    final modelName = _modelOrDefault(agentId, assignment.modelName);
    final id = assignment.id.trim().isEmpty
        ? '$idPrefix-$agentId-0'
        : assignment.id.trim();
    return DailyConversationAgentAssignment(
      id: id,
      agentId: agentId,
      modelName: modelName,
      reasoningEffort: _reasoningOrDefault(
        agentId,
        modelName,
        assignment.reasoningEffort,
      ),
      fast: assignment.fast,
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

  void _save() {
    Navigator.of(
      context,
    ).pop(_policy.withCommanderSyncedFromDailyConversation());
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final targets = agentOrchestrationCommanderTargets(
      widget.controller.orchestrationAvailableTargets,
    );
    return Dialog(
      backgroundColor: colors.surface,
      insetPadding: const EdgeInsets.symmetric(horizontal: 48, vertical: 36),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(LicoRadius.floating),
      ),
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
                    targets: targets,
                    onChanged: _setDailyConversationAgents,
                  ),
                  const SizedBox(height: 18),
                  AgentOrchestrationCodeEngineeringPolicyCard(
                    policy: _policy,
                    targets: targets,
                    onDesignerChanged: (agents) => setState(() {
                      _policy = _policy.copyWith(designerAgents: agents);
                    }),
                    onWorkerChanged: (agents) => setState(() {
                      _policy = _policy.copyWith(workerAgents: agents);
                    }),
                    onReviewerChanged: (agents) => setState(() {
                      _policy = _policy.copyWith(reviewerAgents: agents);
                    }),
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
