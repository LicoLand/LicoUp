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
    this.designerAgents = const [],
    this.workerAgents = const [],
    this.reviewerAgents = const [],
  });

  /// Participants invited into everyday (non–code-engineering) conversation.
  final List<DailyConversationAgentAssignment> dailyConversationAgents;
  final String commanderAgentId;
  final String commanderModelName;
  final String commanderReasoningEffort;

  /// Code-engineering multi-capsule lists (order is priority). Worker/Reviewer
  /// project to backend/frontend lanes: first capsule → backend, second →
  /// frontend (or the sole capsule for both lanes).
  final List<DailyConversationAgentAssignment> designerAgents;
  final List<DailyConversationAgentAssignment> workerAgents;
  final List<DailyConversationAgentAssignment> reviewerAgents;

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

  /// Agent that owns plain-send (no `@`) turns and the flywheel capsule chrome:
  /// first Daily Conversation capsule, else Current Conversation (`main_agent`).
  String get plainSendDispatchAgentId {
    final daily = primaryDailyConversationAgent?.agentId.trim() ?? '';
    if (daily.isNotEmpty) return daily;
    return commanderAgentId.trim();
  }

  /// Model override for [plainSendDispatchAgentId].
  String get plainSendModelName {
    final primary = primaryDailyConversationAgent;
    if (primary != null && primary.agentId.trim().isNotEmpty) {
      return primary.modelName.trim();
    }
    return commanderModelName.trim();
  }

  /// Reasoning-effort override for [plainSendDispatchAgentId].
  String get plainSendReasoningEffort {
    final primary = primaryDailyConversationAgent;
    if (primary != null && primary.agentId.trim().isNotEmpty) {
      return primary.reasoningEffort.trim();
    }
    return commanderReasoningEffort.trim();
  }

  /// A current-conversation selection is usable without an explicit model
  /// override.
  ///
  /// **Daily Conversation** is the configured priority list: its first capsule
  /// is the default Current Conversation, and list order is also the automatic
  /// quota / credit / rate-limit / capacity fallback chain for the Lico group
  /// send path. **Current Conversation** ([commanderAgentId] / model / effort)
  /// is the active plain-send owner. When Current matches a Daily capsule
  /// (including after a successful fallback to a later capsule), that Current
  /// selection is preserved; a stale Current outside the Daily list is synced
  /// back to the first capsule. Saving the Adaptive Flywheel dialog also
  /// re-syncs Current from the first Daily capsule. Fallback success updates
  /// Current without reordering this list.
  ///
  /// Some native runtimes do not publish a model catalog. In that case an
  /// empty model delegates model selection to the runtime and must not erase
  /// or disable the selected current-conversation agent.
  bool get configured =>
      primaryDailyConversationAgent != null ||
      commanderAgentId.trim().isNotEmpty;

  bool get codeEngineeringConfigured =>
      _primaryCapsule(designerAgents) != null &&
      _primaryCapsule(workerAgents) != null &&
      _primaryCapsule(reviewerAgents) != null;

  /// Slot projection used by roster sync and Subagent MCP's five-path shape.
  AgentOrchestrationRoleAssignment assignmentFor(
    CodeEngineeringRoleSlot role,
  ) {
    final capsule = switch (role) {
      CodeEngineeringRoleSlot.designer => _primaryCapsule(designerAgents),
      CodeEngineeringRoleSlot.backendWorker => _primaryCapsule(workerAgents),
      CodeEngineeringRoleSlot.frontendWorker =>
        _laneCapsule(workerAgents, frontend: true),
      CodeEngineeringRoleSlot.backendReviewer => _primaryCapsule(reviewerAgents),
      CodeEngineeringRoleSlot.frontendReviewer =>
        _laneCapsule(reviewerAgents, frontend: true),
    };
    if (capsule == null) return const AgentOrchestrationRoleAssignment();
    return AgentOrchestrationRoleAssignment(
      agentId: capsule.agentId,
      modelName: capsule.modelName,
      reasoningEffort: capsule.reasoningEffort,
    );
  }

  /// Distinct agent ids across every code-engineering capsule.
  Iterable<String> get codeEngineeringAgentIds sync* {
    final seen = <String>{};
    for (final list in [designerAgents, workerAgents, reviewerAgents]) {
      for (final assignment in list) {
        final id = assignment.agentId.trim();
        if (id.isNotEmpty && seen.add(id)) yield id;
      }
    }
  }

  /// Distinct Adaptive Flywheel agents for the Lico group roster, in role
  /// order: Daily Conversation → Current Conversation → code-engineering
  /// capsules (Designer / Worker / Reviewer).
  List<String> get flywheelRosterAgentIds {
    final seen = <String>{};
    final ids = <String>[];
    void put(String agentId) {
      final id = agentId.trim();
      if (id.isEmpty || !seen.add(id)) return;
      ids.add(id);
    }

    for (final agentId in dailyConversationAgentIds) {
      put(agentId);
    }
    put(commanderAgentId);
    for (final agentId in codeEngineeringAgentIds) {
      put(agentId);
    }
    return ids;
  }

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

  /// Capsules strictly after the Current Conversation match in list order.
  ///
  /// Used when a Lico group send hits quota / credit / rate-limit / capacity:
  /// later Daily Conversation combinations are tried in priority order.
  /// Unique by `(agentId, modelName)`. Empty when Current Conversation is not
  /// found in the Daily Conversation list.
  List<DailyConversationAgentAssignment>
  dailyConversationFallbackCandidatesAfterCurrent() {
    final match = dailyConversationMatchForCurrentConversation();
    if (match == null) return const [];
    var passedMatch = false;
    final seen = <String>{};
    final out = <DailyConversationAgentAssignment>[];
    for (final assignment in dailyConversationAgents) {
      if (!assignment.configured) continue;
      if (!passedMatch) {
        final sameId =
            match.id.trim().isNotEmpty &&
            assignment.id.trim() == match.id.trim();
        final sameCombo =
            assignment.agentId.trim() == match.agentId.trim() &&
            assignment.modelName.trim() == match.modelName.trim();
        if (sameId || sameCombo) {
          passedMatch = true;
          seen.add(
            '${assignment.agentId.trim()}\u0000${assignment.modelName.trim()}',
          );
        }
        continue;
      }
      final key =
          '${assignment.agentId.trim()}\u0000${assignment.modelName.trim()}';
      if (!seen.add(key)) continue;
      out.add(assignment);
    }
    return List.unmodifiable(out);
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
    List<DailyConversationAgentAssignment>? designerAgents,
    List<DailyConversationAgentAssignment>? workerAgents,
    List<DailyConversationAgentAssignment>? reviewerAgents,
  }) {
    return AgentOrchestrationPolicy(
      dailyConversationAgents: List.unmodifiable(
        dailyConversationAgents ?? this.dailyConversationAgents,
      ),
      commanderAgentId: commanderAgentId ?? this.commanderAgentId,
      commanderModelName: commanderModelName ?? this.commanderModelName,
      commanderReasoningEffort:
          commanderReasoningEffort ?? this.commanderReasoningEffort,
      designerAgents: List.unmodifiable(designerAgents ?? this.designerAgents),
      workerAgents: List.unmodifiable(workerAgents ?? this.workerAgents),
      reviewerAgents: List.unmodifiable(reviewerAgents ?? this.reviewerAgents),
    );
  }

  Map<String, Object?> toTomlConfig() {
    final designerPrimary = assignmentFor(CodeEngineeringRoleSlot.designer);
    final workerBackend = assignmentFor(CodeEngineeringRoleSlot.backendWorker);
    final workerFrontend = assignmentFor(
      CodeEngineeringRoleSlot.frontendWorker,
    );
    final reviewerBackend = assignmentFor(
      CodeEngineeringRoleSlot.backendReviewer,
    );
    final reviewerFrontend = assignmentFor(
      CodeEngineeringRoleSlot.frontendReviewer,
    );
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
        // Primary object fields keep Subagent MCP's five-path reader working;
        // `agents` carries the full ordered multi-capsule list for the editor.
        'designer': <String, Object?>{
          ...designerPrimary.toTomlConfig(),
          'agents': [
            for (final assignment in designerAgents)
              if (assignment.configured) assignment.toTomlConfig(),
          ],
        },
        'worker': <String, Object?>{
          'backend': workerBackend.toTomlConfig(),
          'frontend': workerFrontend.toTomlConfig(),
          'agents': [
            for (final assignment in workerAgents)
              if (assignment.configured) assignment.toTomlConfig(),
          ],
        },
        'reviewer': <String, Object?>{
          'backend': reviewerBackend.toTomlConfig(),
          'frontend': reviewerFrontend.toTomlConfig(),
          'agents': [
            for (final assignment in reviewerAgents)
              if (assignment.configured) assignment.toTomlConfig(),
          ],
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
      designerAgents: _codeEngineeringAgents(
        code['designer'],
        fallbackSingles: [code['designer']],
        idPrefix: 'ce-designer',
      ),
      workerAgents: _codeEngineeringAgents(
        worker,
        fallbackSingles: [worker['backend'], worker['frontend']],
        idPrefix: 'ce-worker',
      ),
      reviewerAgents: _codeEngineeringAgents(
        reviewer,
        fallbackSingles: [reviewer['backend'], reviewer['frontend']],
        idPrefix: 'ce-reviewer',
      ),
    );
  }
}

DailyConversationAgentAssignment? _primaryCapsule(
  List<DailyConversationAgentAssignment> agents,
) {
  for (final assignment in agents) {
    if (assignment.configured) return assignment;
  }
  return null;
}

DailyConversationAgentAssignment? _laneCapsule(
  List<DailyConversationAgentAssignment> agents, {
  required bool frontend,
}) {
  final configured = [
    for (final assignment in agents)
      if (assignment.configured) assignment,
  ];
  if (configured.isEmpty) return null;
  if (!frontend || configured.length == 1) return configured.first;
  return configured[1];
}

List<DailyConversationAgentAssignment> _codeEngineeringAgents(
  Object? group, {
  required List<Object?> fallbackSingles,
  required String idPrefix,
}) {
  if (group is Map) {
    final agents = group['agents'];
    if (agents is List && agents.isNotEmpty) {
      return _dailyConversationAssignments(agents, idPrefix: idPrefix);
    }
  }
  if (group is List && group.isNotEmpty) {
    return _dailyConversationAssignments(group, idPrefix: idPrefix);
  }
  final migrated = <DailyConversationAgentAssignment>[];
  final seen = <String>{};
  var index = 0;
  for (final single in fallbackSingles) {
    final role = AgentOrchestrationRoleAssignment.fromTomlConfig(single);
    if (!role.configured) continue;
    final key = '${role.agentId}\u0000${role.modelName}\u0000${role.reasoningEffort}';
    if (!seen.add(key)) continue;
    migrated.add(
      DailyConversationAgentAssignment(
        id: '$idPrefix-${role.agentId}-$index',
        agentId: role.agentId,
        modelName: role.modelName,
        reasoningEffort: role.reasoningEffort,
      ),
    );
    index += 1;
  }
  return List.unmodifiable(migrated);
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
    designerAgents: _normalizeDailyConversationAgents(
      targets,
      policy.designerAgents,
      idPrefix: 'ce-designer',
    ),
    workerAgents: _normalizeDailyConversationAgents(
      targets,
      policy.workerAgents,
      idPrefix: 'ce-worker',
    ),
    reviewerAgents: _normalizeDailyConversationAgents(
      targets,
      policy.reviewerAgents,
      idPrefix: 'ce-reviewer',
    ),
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
  final seeded = policy.withDailyConversationSeededFromCommander();
  final dailyAgents = _trimCapsuleList(
    seeded.dailyConversationAgents,
    idPrefix: 'dc',
  );
  // Keep a Current Conversation that still matches a Daily Conversation
  // capsule (for example after quota fallback advanced Current). Only fill or
  // replace Current from the Daily primary when it is unset or stale (not in
  // the Daily list — e.g. Cursor left over from an older save). When the agent
  // matches but model/effort were left blank, borrow those fields from the
  // matching Daily capsule so the composer flywheel can show
  // agent · model · effort · Fast.
  final preserved = AgentOrchestrationPolicy(
    dailyConversationAgents: dailyAgents,
    commanderAgentId: policy.commanderAgentId.trim(),
    commanderModelName: policy.commanderModelName.trim(),
    commanderReasoningEffort: policy.commanderReasoningEffort.trim(),
    designerAgents: _trimCapsuleList(
      policy.designerAgents,
      idPrefix: 'ce-designer',
    ),
    workerAgents: _trimCapsuleList(policy.workerAgents, idPrefix: 'ce-worker'),
    reviewerAgents: _trimCapsuleList(
      policy.reviewerAgents,
      idPrefix: 'ce-reviewer',
    ),
  );
  if (preserved.commanderAgentId.isEmpty) {
    return preserved.withCommanderSyncedFromDailyConversation();
  }
  final match = preserved.dailyConversationMatchForCurrentConversation();
  if (match == null) {
    // Stale Current outside Daily Conversation must not outrank the priority
    // list.
    return preserved.withCommanderSyncedFromDailyConversation();
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

List<DailyConversationAgentAssignment> _trimCapsuleList(
  Iterable<DailyConversationAgentAssignment> agents, {
  required String idPrefix,
}) {
  final seenIds = <String>{};
  final result = <DailyConversationAgentAssignment>[];
  for (final assignment in agents) {
    final agentId = assignment.agentId.trim();
    if (agentId.isEmpty) continue;
    var id = assignment.id.trim();
    if (id.isEmpty || !seenIds.add(id)) {
      id = '$idPrefix-$agentId-${result.length}';
      seenIds.add(id);
    }
    result.add(
      DailyConversationAgentAssignment(
        id: id,
        agentId: agentId,
        modelName: assignment.modelName.trim(),
        reasoningEffort: assignment.reasoningEffort.trim(),
        fast: assignment.fast,
      ),
    );
  }
  return result;
}

List<DailyConversationAgentAssignment> _normalizeDailyConversationAgents(
  Iterable<TargetCandidate> targets,
  Iterable<DailyConversationAgentAssignment> configured, {
  String idPrefix = 'dc',
}) {
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
      id = '$idPrefix-$agentId-${result.length}';
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
  if (efforts.contains(normalized)) return normalized;
  return agentOrchestrationDefaultReasoningEffortForModel(
    commander,
    commanderModelName,
  );
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
  Object? value, {
  String idPrefix = 'dc',
}) {
  if (value is! List) return const [];
  final seenIds = <String>{};
  final result = <DailyConversationAgentAssignment>[];
  for (final entry in value) {
    final assignment = DailyConversationAgentAssignment.fromTomlConfig(entry);
    final agentId = assignment.agentId.trim();
    if (agentId.isEmpty) continue;
    var id = assignment.id.trim();
    if (id.isEmpty || !seenIds.add(id)) {
      id = '$idPrefix-$agentId-${result.length}';
      seenIds.add(id);
    }
    result.add(assignment.id == id ? assignment : assignment.copyWith(id: id));
  }
  return result;
}
