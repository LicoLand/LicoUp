import 'package:flutter/foundation.dart';

import 'package:licoup/src/application/features/agents/orchestration/orchestration_target_catalog.dart';
import 'package:licoup/src/contracts/target_candidate.dart';

enum CodeEngineeringRoleSlot {
  designer('designer'),
  backendWorker('backendWorker'),
  frontendWorker('frontendWorker'),
  backendReviewer('backendReviewer'),
  frontendReviewer('frontendReviewer');

  const CodeEngineeringRoleSlot(this.configKey);

  final String configKey;
}

@immutable
final class AgentOrchestrationRoleAssignment {
  const AgentOrchestrationRoleAssignment({
    this.agentId = '',
    this.modelName = '',
    this.reasoningEffort = '',
  });

  final String agentId;
  final String modelName;
  final String reasoningEffort;

  bool get configured => agentId.trim().isNotEmpty;

  AgentOrchestrationRoleAssignment copyWith({
    String? agentId,
    String? modelName,
    String? reasoningEffort,
  }) {
    return AgentOrchestrationRoleAssignment(
      agentId: agentId ?? this.agentId,
      modelName: modelName ?? this.modelName,
      reasoningEffort: reasoningEffort ?? this.reasoningEffort,
    );
  }

  Map<String, Object?> toTomlConfig() => <String, Object?>{
    'agent': agentId.trim(),
    'model': modelName.trim(),
    'reasoning_effort': reasoningEffort.trim(),
  };

  static AgentOrchestrationRoleAssignment fromTomlConfig(Object? value) {
    if (value is! Map) return const AgentOrchestrationRoleAssignment();
    final config = Map<String, Object?>.from(value);
    return AgentOrchestrationRoleAssignment(
      agentId: _string(config['agent']),
      modelName: _string(config['model']),
      reasoningEffort: _string(config['reasoning_effort']),
    );
  }
}

/// Local main-agent selection. A plugin-ready Codex main agent owns dispatch;
/// otherwise LicoUp's native sequential workflow is the fallback owner.
@immutable
final class AgentOrchestrationPolicy {
  const AgentOrchestrationPolicy({
    this.commanderAgentId = '',
    this.commanderModelName = '',
    this.commanderReasoningEffort = '',
    this.codeEngineeringRoles = const {},
  });

  final String commanderAgentId;
  final String commanderModelName;
  final String commanderReasoningEffort;
  final Map<CodeEngineeringRoleSlot, AgentOrchestrationRoleAssignment>
  codeEngineeringRoles;

  /// A main-agent selection is usable without an explicit model override.
  ///
  /// Some native runtimes do not publish a model catalog. In that case an
  /// empty model delegates model selection to the runtime and must not erase
  /// or disable the selected main agent.
  bool get configured => commanderAgentId.trim().isNotEmpty;

  bool get codeEngineeringConfigured => CodeEngineeringRoleSlot.values.every(
    (role) => assignmentFor(role).configured,
  );

  AgentOrchestrationRoleAssignment assignmentFor(
    CodeEngineeringRoleSlot role,
  ) => codeEngineeringRoles[role] ?? const AgentOrchestrationRoleAssignment();

  AgentOrchestrationPolicy copyWith({
    String? commanderAgentId,
    String? commanderModelName,
    String? commanderReasoningEffort,
    Map<CodeEngineeringRoleSlot, AgentOrchestrationRoleAssignment>?
    codeEngineeringRoles,
  }) {
    return AgentOrchestrationPolicy(
      commanderAgentId: commanderAgentId ?? this.commanderAgentId,
      commanderModelName: commanderModelName ?? this.commanderModelName,
      commanderReasoningEffort:
          commanderReasoningEffort ?? this.commanderReasoningEffort,
      codeEngineeringRoles: Map.unmodifiable(
        codeEngineeringRoles ?? this.codeEngineeringRoles,
      ),
    );
  }

  Map<String, Object?> toTomlConfig() {
    return <String, Object?>{
      'version': 1,
      'main_agent': <String, Object?>{
        'agent': commanderAgentId.trim(),
        'model': commanderModelName.trim(),
        'reasoning_effort': commanderReasoningEffort.trim(),
      },
      'code_engineering': <String, Object?>{
        'strategy': 'frontend_backend_roles',
        'designer': assignmentFor(
          CodeEngineeringRoleSlot.designer,
        ).toTomlConfig(),
        'worker': <String, Object?>{
          'backend': assignmentFor(
            CodeEngineeringRoleSlot.backendWorker,
          ).toTomlConfig(),
          'frontend': assignmentFor(
            CodeEngineeringRoleSlot.frontendWorker,
          ).toTomlConfig(),
        },
        'reviewer': <String, Object?>{
          'backend': assignmentFor(
            CodeEngineeringRoleSlot.backendReviewer,
          ).toTomlConfig(),
          'frontend': assignmentFor(
            CodeEngineeringRoleSlot.frontendReviewer,
          ).toTomlConfig(),
        },
      },
    };
  }

  static AgentOrchestrationPolicy fromTomlConfig(Map<String, Object?> config) {
    final mainAgent = config['main_agent'];
    final main = mainAgent is Map ? mainAgent : const {};
    final codeEngineering = config['code_engineering'];
    final code = codeEngineering is Map ? codeEngineering : const {};
    final worker = code['worker'] is Map ? code['worker'] as Map : const {};
    final reviewer = code['reviewer'] is Map
        ? code['reviewer'] as Map
        : const {};
    return AgentOrchestrationPolicy(
      commanderAgentId: _string(main['agent']),
      commanderModelName: _string(main['model']),
      commanderReasoningEffort: _string(main['reasoning_effort']),
      codeEngineeringRoles: Map.unmodifiable(<
        CodeEngineeringRoleSlot,
        AgentOrchestrationRoleAssignment
      >{
        CodeEngineeringRoleSlot.designer:
            AgentOrchestrationRoleAssignment.fromTomlConfig(code['designer']),
        CodeEngineeringRoleSlot.backendWorker:
            AgentOrchestrationRoleAssignment.fromTomlConfig(worker['backend']),
        CodeEngineeringRoleSlot.frontendWorker:
            AgentOrchestrationRoleAssignment.fromTomlConfig(worker['frontend']),
        CodeEngineeringRoleSlot.backendReviewer:
            AgentOrchestrationRoleAssignment.fromTomlConfig(
              reviewer['backend'],
            ),
        CodeEngineeringRoleSlot.frontendReviewer:
            AgentOrchestrationRoleAssignment.fromTomlConfig(
              reviewer['frontend'],
            ),
      }),
    );
  }
}

AgentOrchestrationPolicy sanitizeOrchestrationPolicyEditorDraft(
  Iterable<TargetCandidate> targets,
  AgentOrchestrationPolicy policy,
) {
  final commanderAgentId = _normalizeCommanderAgentId(
    targets,
    policy.commanderAgentId,
  );
  final commanderModelName = _normalizeCommanderModelName(
    targets,
    commanderAgentId,
    policy.commanderModelName,
  );
  return policy.copyWith(
    commanderAgentId: commanderAgentId,
    commanderModelName: commanderModelName,
    commanderReasoningEffort: _normalizeCommanderReasoningEffort(
      targets,
      commanderAgentId,
      commanderModelName,
      policy.commanderReasoningEffort,
    ),
    codeEngineeringRoles: Map.unmodifiable({
      for (final role in CodeEngineeringRoleSlot.values)
        role: _normalizeRoleAssignment(targets, policy.assignmentFor(role)),
    }),
  );
}

/// Normalizes user input for persistence without treating the live runtime
/// scan as the source of truth for saved configuration.
///
/// Target discovery is asynchronous and may briefly publish an empty or
/// paint-only catalog while the policy dialog is open. Persisting through the
/// catalog-aware editor sanitizer would erase a valid selection during that
/// window. Runtime availability is checked separately when a conversation is
/// dispatched.
AgentOrchestrationPolicy normalizeOrchestrationPolicyForPersistence(
  AgentOrchestrationPolicy policy,
) {
  AgentOrchestrationRoleAssignment normalizeAssignment(
    AgentOrchestrationRoleAssignment assignment,
  ) {
    return AgentOrchestrationRoleAssignment(
      agentId: assignment.agentId.trim(),
      modelName: assignment.modelName.trim(),
      reasoningEffort: assignment.reasoningEffort.trim(),
    );
  }

  return AgentOrchestrationPolicy(
    commanderAgentId: policy.commanderAgentId.trim(),
    commanderModelName: policy.commanderModelName.trim(),
    commanderReasoningEffort: policy.commanderReasoningEffort.trim(),
    codeEngineeringRoles: Map.unmodifiable({
      for (final role in CodeEngineeringRoleSlot.values)
        role: normalizeAssignment(policy.assignmentFor(role)),
    }),
  );
}

AgentOrchestrationRoleAssignment _normalizeRoleAssignment(
  Iterable<TargetCandidate> targets,
  AgentOrchestrationRoleAssignment assignment,
) {
  final agentId = _normalizeCommanderAgentId(targets, assignment.agentId);
  final modelName = _normalizeCommanderModelName(
    targets,
    agentId,
    assignment.modelName,
  );
  return AgentOrchestrationRoleAssignment(
    agentId: agentId,
    modelName: modelName,
    reasoningEffort: _normalizeCommanderReasoningEffort(
      targets,
      agentId,
      modelName,
      assignment.reasoningEffort,
    ),
  );
}

String _normalizeCommanderAgentId(
  Iterable<TargetCandidate> targets,
  String configuredAgentId,
) {
  final normalized = configuredAgentId.trim();
  return agentOrchestrationCommanderTargets(
        targets,
      ).any((target) => target.target == normalized)
      ? normalized
      : '';
}

String _normalizeCommanderModelName(
  Iterable<TargetCandidate> targets,
  String commanderAgentId,
  String configuredModelName,
) {
  final commander = _targetById(targets, commanderAgentId);
  if (commander == null) return '';
  final models = agentOrchestrationCommanderModels(commander);
  if (models.isEmpty) return '';
  final normalized = configuredModelName.trim();
  return models.contains(normalized) ? normalized : models.first;
}

String _normalizeCommanderReasoningEffort(
  Iterable<TargetCandidate> targets,
  String commanderAgentId,
  String commanderModelName,
  String configuredReasoningEffort,
) {
  if (commanderModelName.trim().isEmpty) return '';
  final commander = _targetById(targets, commanderAgentId);
  if (commander == null) return '';
  final efforts = agentOrchestrationReasoningEffortsForModel(
    commander,
    commanderModelName,
  );
  if (efforts.isEmpty) return '';
  final normalized = configuredReasoningEffort.trim();
  return efforts.contains(normalized) ? normalized : efforts.first;
}

TargetCandidate? _targetById(
  Iterable<TargetCandidate> targets,
  String targetId,
) {
  for (final target in targets) {
    if (target.target == targetId) return target;
  }
  return null;
}

String _string(Object? value, {String fallback = ''}) {
  final normalized = value?.toString().trim() ?? '';
  return normalized.isEmpty ? fallback : normalized;
}
