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

/// One everyday-conversation capsule: agent plus optional model, effort, and
/// Fast routing. Multiple capsules may share the same agent with different
/// model/effort combinations; [id] distinguishes each saved entry.
@immutable
final class DailyConversationAgentAssignment {
  const DailyConversationAgentAssignment({
    this.id = '',
    this.agentId = '',
    this.modelName = '',
    this.reasoningEffort = '',
    this.fast = false,
  });

  final String id;
  final String agentId;
  final String modelName;
  final String reasoningEffort;
  final bool fast;

  bool get configured => agentId.trim().isNotEmpty;

  DailyConversationAgentAssignment copyWith({
    String? id,
    String? agentId,
    String? modelName,
    String? reasoningEffort,
    bool? fast,
  }) {
    return DailyConversationAgentAssignment(
      id: id ?? this.id,
      agentId: agentId ?? this.agentId,
      modelName: modelName ?? this.modelName,
      reasoningEffort: reasoningEffort ?? this.reasoningEffort,
      fast: fast ?? this.fast,
    );
  }

  Map<String, Object?> toTomlConfig() => <String, Object?>{
    'id': id.trim(),
    'agent': agentId.trim(),
    'model': modelName.trim(),
    'reasoning_effort': reasoningEffort.trim(),
    'fast': fast,
  };

  static DailyConversationAgentAssignment fromTomlConfig(Object? value) {
    if (value is String) {
      final agentId = value.trim();
      return agentId.isEmpty
          ? const DailyConversationAgentAssignment()
          : DailyConversationAgentAssignment(agentId: agentId);
    }
    if (value is! Map) return const DailyConversationAgentAssignment();
    final config = Map<String, Object?>.from(value);
    return DailyConversationAgentAssignment(
      id: _string(config['id']),
      agentId: _string(config['agent']),
      modelName: _string(config['model']),
      reasoningEffort: _string(config['reasoning_effort']),
      fast: config['fast'] == true,
    );
  }
}

/// Local main-agent selection. A plugin-ready Codex main agent owns dispatch;
/// otherwise LicoUp's native sequential workflow is the fallback owner.
@immutable
final class AgentOrchestrationPolicy {
  const AgentOrchestrationPolicy({
    this.dailyConversationAgents = const [],
    this.commanderAgentId = '',
    this.commanderModelName = '',
    this.commanderReasoningEffort = '',
    this.codeEngineeringRoles = const {},
  });

  /// Participants invited into everyday (non–code-engineering) conversation.
  final List<DailyConversationAgentAssignment> dailyConversationAgents;
  final String commanderAgentId;
  final String commanderModelName;
  final String commanderReasoningEffort;
  final Map<CodeEngineeringRoleSlot, AgentOrchestrationRoleAssignment>
  codeEngineeringRoles;

  /// Distinct agent ids — used by roster sync (order follows first appearance).
  List<String> get dailyConversationAgentIds {
    final seen = <String>{};
    return [
      for (final assignment in dailyConversationAgents)
        if (assignment.agentId.trim().isNotEmpty &&
            seen.add(assignment.agentId.trim()))
          assignment.agentId.trim(),
    ];
  }

  /// Highest-priority everyday combination (list order).
  DailyConversationAgentAssignment? get primaryDailyConversationAgent {
    for (final assignment in dailyConversationAgents) {
      if (assignment.configured) return assignment;
    }
    return null;
  }

  /// A current-conversation selection is usable without an explicit model
  /// override.
  ///
  /// **Daily Conversation** is the configured priority list; its first capsule
  /// is the default dispatch owner. **Current Conversation**
  /// ([commanderAgentId] / model / effort) is the active owner for the live
  /// Lico group entry. When the two differ, Current Conversation wins for
  /// dispatch; Daily Conversation stays the Adaptive Flywheel default until
  /// the dialog is saved again (which re-syncs Current from the first capsule).
  ///
  /// Some native runtimes do not publish a model catalog. In that case an
  /// empty model delegates model selection to the runtime and must not erase
  /// or disable the selected current-conversation agent.
  bool get configured =>
      primaryDailyConversationAgent != null ||
      commanderAgentId.trim().isNotEmpty;

  bool get codeEngineeringConfigured => CodeEngineeringRoleSlot.values.every(
    (role) => assignmentFor(role).configured,
  );

  AgentOrchestrationRoleAssignment assignmentFor(
    CodeEngineeringRoleSlot role,
  ) => codeEngineeringRoles[role] ?? const AgentOrchestrationRoleAssignment();

  DailyConversationAgentAssignment? dailyConversationAssignmentFor(
    String agentId,
  ) {
    final normalized = agentId.trim();
    if (normalized.isEmpty) return null;
    for (final assignment in dailyConversationAgents) {
      if (assignment.agentId.trim() == normalized) return assignment;
    }
    return null;
  }

  /// Daily Conversation capsule that best matches Current Conversation
  /// (`main_agent`): prefer same agent + model, else the first same agent.
  /// Used for display fields such as Fast that live only on daily capsules.
  DailyConversationAgentAssignment? dailyConversationMatchForCurrentConversation() {
    final agentId = commanderAgentId.trim();
    if (agentId.isEmpty) return null;
    final model = commanderModelName.trim();
    DailyConversationAgentAssignment? agentOnly;
    for (final assignment in dailyConversationAgents) {
      if (assignment.agentId.trim() != agentId) continue;
      if (model.isNotEmpty && assignment.modelName.trim() == model) {
        return assignment;
      }
      agentOnly ??= assignment;
    }
    return agentOnly;
  }

  /// Seeds everyday conversation from a legacy `main_agent` block when the
  /// Daily Conversation list is empty.
  AgentOrchestrationPolicy withDailyConversationSeededFromCommander() {
    if (primaryDailyConversationAgent != null) return this;
    final agentId = commanderAgentId.trim();
    if (agentId.isEmpty) return this;
    return copyWith(
      dailyConversationAgents: [
        DailyConversationAgentAssignment(
          id: 'dc-migrated-$agentId',
          agentId: agentId,
          modelName: commanderModelName.trim(),
          reasoningEffort: commanderReasoningEffort.trim(),
        ),
      ],
    );
  }

  /// Projects the first Daily Conversation capsule onto Current Conversation
  /// (`main_agent`) fields. Used when saving Adaptive Flywheel so the default
  /// priority list resets the live dispatch owner.
  AgentOrchestrationPolicy withCommanderSyncedFromDailyConversation() {
    final primary = primaryDailyConversationAgent;
    if (primary == null) {
      return copyWith(
        commanderAgentId: '',
        commanderModelName: '',
        commanderReasoningEffort: '',
      );
    }
    return copyWith(
      commanderAgentId: primary.agentId.trim(),
      commanderModelName: primary.modelName.trim(),
      commanderReasoningEffort: primary.reasoningEffort.trim(),
    );
  }

  AgentOrchestrationPolicy copyWith({
    List<DailyConversationAgentAssignment>? dailyConversationAgents,
    String? commanderAgentId,
    String? commanderModelName,
    String? commanderReasoningEffort,
    Map<CodeEngineeringRoleSlot, AgentOrchestrationRoleAssignment>?
    codeEngineeringRoles,
  }) {
    return AgentOrchestrationPolicy(
      dailyConversationAgents: List.unmodifiable(
        dailyConversationAgents ?? this.dailyConversationAgents,
      ),
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
      'daily_conversation': <String, Object?>{
        'agents': [
          for (final assignment in dailyConversationAgents)
            if (assignment.configured) assignment.toTomlConfig(),
        ],
      },
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
    final dailyConversation = config['daily_conversation'];
    final daily = dailyConversation is Map ? dailyConversation : const {};
    return AgentOrchestrationPolicy(
      dailyConversationAgents: _dailyConversationAssignments(daily['agents']),
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
  final seeded = policy.withDailyConversationSeededFromCommander();
  final dailyAgents = _normalizeDailyConversationAgents(
    targets,
    seeded.dailyConversationAgents,
  );
  final synced = seeded
      .copyWith(dailyConversationAgents: dailyAgents)
      .withCommanderSyncedFromDailyConversation();
  final commanderAgentId = _normalizeCommanderAgentId(
    targets,
    synced.commanderAgentId,
  );
  final commanderModelName = _normalizeCommanderModelName(
    targets,
    commanderAgentId,
    synced.commanderModelName,
  );
  return synced.copyWith(
    commanderAgentId: commanderAgentId,
    commanderModelName: commanderModelName,
    commanderReasoningEffort: _normalizeCommanderReasoningEffort(
      targets,
      commanderAgentId,
      commanderModelName,
      synced.commanderReasoningEffort,
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

  final seeded = policy.withDailyConversationSeededFromCommander();
  final seenIds = <String>{};
  final dailyAgents = <DailyConversationAgentAssignment>[];
  for (final assignment in seeded.dailyConversationAgents) {
    final agentId = assignment.agentId.trim();
    if (agentId.isEmpty) continue;
    var id = assignment.id.trim();
    if (id.isEmpty || !seenIds.add(id)) {
      id = 'dc-$agentId-${dailyAgents.length}';
      seenIds.add(id);
    }
    dailyAgents.add(
      DailyConversationAgentAssignment(
        id: id,
        agentId: agentId,
        modelName: assignment.modelName.trim(),
        reasoningEffort: assignment.reasoningEffort.trim(),
        fast: assignment.fast,
      ),
    );
  }
  // Preserve an explicit Current Conversation (`main_agent`) selection even
  // when it differs from the first Daily Conversation capsule. Only fill
  // Current Conversation from Daily Conversation when it is unset. When the
  // agent is set but model/effort were left blank, borrow those fields from
  // the matching Daily Conversation capsule so the composer flywheel can show
  // agent · model · effort · Fast.
  final preserved = AgentOrchestrationPolicy(
    dailyConversationAgents: dailyAgents,
    commanderAgentId: policy.commanderAgentId.trim(),
    commanderModelName: policy.commanderModelName.trim(),
    commanderReasoningEffort: policy.commanderReasoningEffort.trim(),
    codeEngineeringRoles: Map.unmodifiable({
      for (final role in CodeEngineeringRoleSlot.values)
        role: normalizeAssignment(policy.assignmentFor(role)),
    }),
  );
  if (preserved.commanderAgentId.isEmpty) {
    return preserved.withCommanderSyncedFromDailyConversation();
  }
  final match = preserved.dailyConversationMatchForCurrentConversation();
  if (match == null) {
    return preserved;
  }
  return preserved.copyWith(
    commanderModelName: preserved.commanderModelName.isNotEmpty
        ? preserved.commanderModelName
        : match.modelName.trim(),
    commanderReasoningEffort: preserved.commanderReasoningEffort.isNotEmpty
        ? preserved.commanderReasoningEffort
        : match.reasoningEffort.trim(),
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

List<DailyConversationAgentAssignment> _normalizeDailyConversationAgents(
  Iterable<TargetCandidate> targets,
  Iterable<DailyConversationAgentAssignment> configured,
) {
  final available = {
    for (final target in agentOrchestrationCommanderTargets(targets))
      target.target: target,
  };
  final seenIds = <String>{};
  final result = <DailyConversationAgentAssignment>[];
  for (final assignment in configured) {
    final agentId = assignment.agentId.trim();
    if (available[agentId] == null) continue;
    var id = assignment.id.trim();
    if (id.isEmpty || !seenIds.add(id)) {
      id = 'dc-$agentId-${result.length}';
      seenIds.add(id);
    }
    final modelName = _normalizeCommanderModelName(
      targets,
      agentId,
      assignment.modelName,
    );
    result.add(
      DailyConversationAgentAssignment(
        id: id,
        agentId: agentId,
        modelName: modelName,
        reasoningEffort: _normalizeCommanderReasoningEffort(
          targets,
          agentId,
          modelName,
          assignment.reasoningEffort,
        ),
        fast: assignment.fast,
      ),
    );
  }
  return result;
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

List<DailyConversationAgentAssignment> _dailyConversationAssignments(
  Object? value,
) {
  if (value is! List) return const [];
  final seenIds = <String>{};
  final result = <DailyConversationAgentAssignment>[];
  for (final entry in value) {
    final assignment = DailyConversationAgentAssignment.fromTomlConfig(entry);
    final agentId = assignment.agentId.trim();
    if (agentId.isEmpty) continue;
    var id = assignment.id.trim();
    if (id.isEmpty || !seenIds.add(id)) {
      id = 'dc-$agentId-${result.length}';
      seenIds.add(id);
    }
    result.add(assignment.id == id ? assignment : assignment.copyWith(id: id));
  }
  return result;
}
