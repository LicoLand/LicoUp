import 'package:licoup/src/presentation/presentation_semantics.dart';

final class AcativaDefinitionProjection {
  const AcativaDefinitionProjection({
    required this.id,
    required this.name,
    required this.version,
    required this.revision,
    required this.authorized,
  });

  final String id;
  final String name;
  final String version;
  final String revision;
  final bool authorized;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AcativaDefinitionProjection &&
          other.id == id &&
          other.name == name &&
          other.version == version &&
          other.revision == revision &&
          other.authorized == authorized;

  @override
  int get hashCode => Object.hash(id, name, version, revision, authorized);
}

final class AcativaSlotProjection {
  const AcativaSlotProjection({
    required this.id,
    required this.kind,
    required this.label,
    required this.required,
    required this.entry,
  });

  final String id;
  final String kind;
  final String label;
  final bool required;
  final bool entry;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AcativaSlotProjection &&
          other.id == id &&
          other.kind == kind &&
          other.label == label &&
          other.required == required &&
          other.entry == entry;

  @override
  int get hashCode => Object.hash(id, kind, label, required, entry);
}

final class AcativaAssignmentProjection {
  const AcativaAssignmentProjection({
    required this.slotId,
    required this.ordinal,
    required this.agentId,
    required this.modelId,
    required this.reasoningEffort,
    required this.revision,
  });

  final String slotId;
  final int ordinal;
  final String agentId;
  final String modelId;
  final String reasoningEffort;
  final int revision;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AcativaAssignmentProjection &&
          other.slotId == slotId &&
          other.ordinal == ordinal &&
          other.agentId == agentId &&
          other.modelId == modelId &&
          other.reasoningEffort == reasoningEffort &&
          other.revision == revision;

  @override
  int get hashCode =>
      Object.hash(slotId, ordinal, agentId, modelId, reasoningEffort, revision);
}

final class AcativaGraphStateProjection {
  const AcativaGraphStateProjection({
    required this.id,
    required this.kind,
    required this.label,
  });

  final String id;
  final String kind;
  final String label;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AcativaGraphStateProjection &&
          other.id == id &&
          other.kind == kind &&
          other.label == label;

  @override
  int get hashCode => Object.hash(id, kind, label);
}

final class AcativaGraphEdgeProjection {
  const AcativaGraphEdgeProjection({
    required this.from,
    required this.to,
    required this.event,
    this.mode = 'flow',
    required this.guardLabel,
  });

  final String from;
  final String to;
  final String event;
  final String mode;
  final String guardLabel;

  bool get callback => mode == 'callback';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AcativaGraphEdgeProjection &&
          other.from == from &&
          other.to == to &&
          other.event == event &&
          other.mode == mode &&
          other.guardLabel == guardLabel;

  @override
  int get hashCode => Object.hash(from, to, event, mode, guardLabel);
}

final class AcativaInspectionProjection {
  AcativaInspectionProjection({
    required this.status,
    required Iterable<String> currentStates,
    required Iterable<String> neighborStates,
    required Iterable<String> allowedOperations,
    required Iterable<AcativaAssignmentProjection> assignments,
    required Iterable<AcativaSlotProjection> slots,
    required Iterable<AcativaGraphStateProjection> states,
    required Iterable<AcativaGraphEdgeProjection> edges,
    required this.initialState,
    required this.diagnosticCode,
    Map<String, String> modelDisplayNames = const {},
  }) : modelDisplayNames = Map.unmodifiable(modelDisplayNames),
       currentStates = immutablePresentationList(currentStates),
       neighborStates = immutablePresentationList(neighborStates),
       allowedOperations = immutablePresentationList(allowedOperations),
       assignments = immutablePresentationList(assignments),
       slots = immutablePresentationList(slots),
       states = immutablePresentationList(states),
       edges = immutablePresentationList(edges);

  final String status;
  final List<String> currentStates;
  final List<String> neighborStates;
  final List<String> allowedOperations;
  final List<AcativaAssignmentProjection> assignments;
  final List<AcativaSlotProjection> slots;
  final List<AcativaGraphStateProjection> states;
  final List<AcativaGraphEdgeProjection> edges;
  final String initialState;
  final String diagnosticCode;
  final Map<String, String> modelDisplayNames;

  List<AcativaAssignmentProjection> assignmentsFor(String slotId) =>
      List<AcativaAssignmentProjection>.unmodifiable(
        assignments.where((assignment) => assignment.slotId == slotId),
      );

  bool get authorized => allowedOperations.contains('strategy.run.start');

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AcativaInspectionProjection &&
          other.status == status &&
          samePresentationList(other.currentStates, currentStates) &&
          samePresentationList(other.neighborStates, neighborStates) &&
          samePresentationList(other.allowedOperations, allowedOperations) &&
          samePresentationList(other.assignments, assignments) &&
          samePresentationList(other.slots, slots) &&
          samePresentationList(other.states, states) &&
          samePresentationList(other.edges, edges) &&
          other.initialState == initialState &&
          other.diagnosticCode == diagnosticCode &&
          other.modelDisplayNames.length == modelDisplayNames.length &&
          modelDisplayNames.entries.every(
            (entry) => other.modelDisplayNames[entry.key] == entry.value,
          );

  @override
  int get hashCode => Object.hash(
    status,
    Object.hashAll(currentStates),
    Object.hashAll(neighborStates),
    Object.hashAll(allowedOperations),
    Object.hashAll(assignments),
    Object.hashAll(slots),
    Object.hashAll(states),
    Object.hashAll(edges),
    initialState,
    diagnosticCode,
    Object.hashAllUnordered(
      modelDisplayNames.entries.map(
        (entry) => Object.hash(entry.key, entry.value),
      ),
    ),
  );
}

final class AcativaModelProjection {
  AcativaModelProjection({
    required this.id,
    required this.label,
    required this.providerId,
    required this.providerLabel,
    required Iterable<String> reasoningEfforts,
    required this.defaultReasoningEffort,
  }) : reasoningEfforts = immutablePresentationList(reasoningEfforts);

  final String id;
  final String label;
  final String providerId;
  final String providerLabel;
  final List<String> reasoningEfforts;
  final String defaultReasoningEffort;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AcativaModelProjection &&
          other.id == id &&
          other.label == label &&
          other.providerId == providerId &&
          other.providerLabel == providerLabel &&
          samePresentationList(other.reasoningEfforts, reasoningEfforts) &&
          other.defaultReasoningEffort == defaultReasoningEffort;

  @override
  int get hashCode => Object.hash(
    id,
    label,
    providerId,
    providerLabel,
    Object.hashAll(reasoningEfforts),
    defaultReasoningEffort,
  );
}

final class AcativaAgentProjection {
  AcativaAgentProjection({
    required this.id,
    required this.displayName,
    required Iterable<AcativaModelProjection> models,
    required Iterable<String> permissionModes,
    required this.refreshingModelCatalog,
  }) : models = immutablePresentationList(models),
       permissionModes = immutablePresentationList(permissionModes);

  final String id;
  final String displayName;
  final List<AcativaModelProjection> models;

  /// Permission modes the runtime adapter can execute; empty when the agent
  /// exposes no client-selectable permission control.
  final List<String> permissionModes;
  final bool refreshingModelCatalog;

  AcativaModelProjection? model(String modelId) {
    for (final model in models) {
      if (model.id == modelId) return model;
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AcativaAgentProjection &&
          other.id == id &&
          other.displayName == displayName &&
          samePresentationList(other.models, models) &&
          samePresentationList(other.permissionModes, permissionModes) &&
          other.refreshingModelCatalog == refreshingModelCatalog;

  @override
  int get hashCode => Object.hash(
    id,
    displayName,
    Object.hashAll(models),
    Object.hashAll(permissionModes),
    refreshingModelCatalog,
  );
}

final class AcativaAssistantProjection {
  const AcativaAssistantProjection({
    required this.conversationId,
    required this.membershipId,
    required this.agentId,
    required this.modelId,
    required this.reasoningEffort,
    required this.permissionMode,
    required this.profileRevision,
    required this.loading,
    required this.saving,
  });

  const AcativaAssistantProjection.empty()
    : conversationId = '',
      membershipId = '',
      agentId = '',
      modelId = '',
      reasoningEffort = '',
      permissionMode = '',
      profileRevision = 0,
      loading = false,
      saving = false;

  final String conversationId;
  final String membershipId;
  final String agentId;
  final String modelId;
  final String reasoningEffort;
  final String permissionMode;
  final int profileRevision;
  final bool loading;
  final bool saving;

  bool get available => conversationId.isNotEmpty;

  AcativaAssistantProjection copyWith({
    String? conversationId,
    String? membershipId,
    String? agentId,
    String? modelId,
    String? reasoningEffort,
    String? permissionMode,
    int? profileRevision,
    bool? loading,
    bool? saving,
  }) => AcativaAssistantProjection(
    conversationId: conversationId ?? this.conversationId,
    membershipId: membershipId ?? this.membershipId,
    agentId: agentId ?? this.agentId,
    modelId: modelId ?? this.modelId,
    reasoningEffort: reasoningEffort ?? this.reasoningEffort,
    permissionMode: permissionMode ?? this.permissionMode,
    profileRevision: profileRevision ?? this.profileRevision,
    loading: loading ?? this.loading,
    saving: saving ?? this.saving,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AcativaAssistantProjection &&
          other.conversationId == conversationId &&
          other.membershipId == membershipId &&
          other.agentId == agentId &&
          other.modelId == modelId &&
          other.reasoningEffort == reasoningEffort &&
          other.permissionMode == permissionMode &&
          other.profileRevision == profileRevision &&
          other.loading == loading &&
          other.saving == saving;

  @override
  int get hashCode => Object.hash(
    conversationId,
    membershipId,
    agentId,
    modelId,
    reasoningEffort,
    permissionMode,
    profileRevision,
    loading,
    saving,
  );
}

final class AcativaProjection {
  AcativaProjection({
    required Iterable<AcativaDefinitionProjection> definitions,
    required this.selectedRevision,
    required this.inspection,
    required Iterable<AcativaAgentProjection> callableAgents,
    required this.assistant,
    required this.busy,
    required this.error,
  }) : definitions = immutablePresentationList(definitions),
       callableAgents = immutablePresentationList(callableAgents);

  factory AcativaProjection.empty() => AcativaProjection(
    definitions: const [],
    selectedRevision: '',
    inspection: null,
    callableAgents: const [],
    assistant: const AcativaAssistantProjection.empty(),
    busy: false,
    error: '',
  );

  final List<AcativaDefinitionProjection> definitions;
  final String selectedRevision;
  final AcativaInspectionProjection? inspection;
  final List<AcativaAgentProjection> callableAgents;
  final AcativaAssistantProjection assistant;
  final bool busy;
  final String error;

  AcativaAgentProjection? agent(String agentId) {
    for (final agent in callableAgents) {
      if (agent.id == agentId) return agent;
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AcativaProjection &&
          samePresentationList(other.definitions, definitions) &&
          other.selectedRevision == selectedRevision &&
          other.inspection == inspection &&
          samePresentationList(other.callableAgents, callableAgents) &&
          other.assistant == assistant &&
          other.busy == busy &&
          other.error == error;

  @override
  int get hashCode => Object.hash(
    Object.hashAll(definitions),
    selectedRevision,
    inspection,
    Object.hashAll(callableAgents),
    assistant,
    busy,
    error,
  );
}
