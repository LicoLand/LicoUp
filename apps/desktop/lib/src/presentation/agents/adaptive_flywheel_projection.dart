import 'package:licoup/src/presentation/presentation_semantics.dart';

final class AdaptiveFlywheelDefinitionProjection {
  const AdaptiveFlywheelDefinitionProjection({
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
      other is AdaptiveFlywheelDefinitionProjection &&
          other.id == id &&
          other.name == name &&
          other.version == version &&
          other.revision == revision &&
          other.authorized == authorized;

  @override
  int get hashCode => Object.hash(id, name, version, revision, authorized);
}

final class AdaptiveFlywheelSlotProjection {
  const AdaptiveFlywheelSlotProjection({
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
      other is AdaptiveFlywheelSlotProjection &&
          other.id == id &&
          other.kind == kind &&
          other.label == label &&
          other.required == required &&
          other.entry == entry;

  @override
  int get hashCode => Object.hash(id, kind, label, required, entry);
}

final class AdaptiveFlywheelAssignmentProjection {
  const AdaptiveFlywheelAssignmentProjection({
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
      other is AdaptiveFlywheelAssignmentProjection &&
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

final class AdaptiveFlywheelGraphStateProjection {
  const AdaptiveFlywheelGraphStateProjection({
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
      other is AdaptiveFlywheelGraphStateProjection &&
          other.id == id &&
          other.kind == kind &&
          other.label == label;

  @override
  int get hashCode => Object.hash(id, kind, label);
}

final class AdaptiveFlywheelGraphEdgeProjection {
  const AdaptiveFlywheelGraphEdgeProjection({
    required this.from,
    required this.to,
    required this.event,
    required this.guardLabel,
  });

  final String from;
  final String to;
  final String event;
  final String guardLabel;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AdaptiveFlywheelGraphEdgeProjection &&
          other.from == from &&
          other.to == to &&
          other.event == event &&
          other.guardLabel == guardLabel;

  @override
  int get hashCode => Object.hash(from, to, event, guardLabel);
}

final class AdaptiveFlywheelInspectionProjection {
  AdaptiveFlywheelInspectionProjection({
    required this.status,
    required Iterable<String> currentStates,
    required Iterable<String> neighborStates,
    required Iterable<String> allowedOperations,
    required Iterable<AdaptiveFlywheelAssignmentProjection> assignments,
    required Iterable<AdaptiveFlywheelSlotProjection> slots,
    required Iterable<AdaptiveFlywheelGraphStateProjection> states,
    required Iterable<AdaptiveFlywheelGraphEdgeProjection> edges,
    required this.initialState,
    required this.diagnosticCode,
  }) : currentStates = immutablePresentationList(currentStates),
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
  final List<AdaptiveFlywheelAssignmentProjection> assignments;
  final List<AdaptiveFlywheelSlotProjection> slots;
  final List<AdaptiveFlywheelGraphStateProjection> states;
  final List<AdaptiveFlywheelGraphEdgeProjection> edges;
  final String initialState;
  final String diagnosticCode;

  List<AdaptiveFlywheelAssignmentProjection> assignmentsFor(String slotId) =>
      List<AdaptiveFlywheelAssignmentProjection>.unmodifiable(
        assignments.where((assignment) => assignment.slotId == slotId),
      );

  bool get authorized => allowedOperations.contains('strategy.run.start');

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AdaptiveFlywheelInspectionProjection &&
          other.status == status &&
          samePresentationList(other.currentStates, currentStates) &&
          samePresentationList(other.neighborStates, neighborStates) &&
          samePresentationList(other.allowedOperations, allowedOperations) &&
          samePresentationList(other.assignments, assignments) &&
          samePresentationList(other.slots, slots) &&
          samePresentationList(other.states, states) &&
          samePresentationList(other.edges, edges) &&
          other.initialState == initialState &&
          other.diagnosticCode == diagnosticCode;

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
  );
}

final class AdaptiveFlywheelModelProjection {
  AdaptiveFlywheelModelProjection({
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
      other is AdaptiveFlywheelModelProjection &&
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

final class AdaptiveFlywheelAgentProjection {
  AdaptiveFlywheelAgentProjection({
    required this.id,
    required this.displayName,
    required Iterable<AdaptiveFlywheelModelProjection> models,
    required this.refreshingModelCatalog,
  }) : models = immutablePresentationList(models);

  final String id;
  final String displayName;
  final List<AdaptiveFlywheelModelProjection> models;
  final bool refreshingModelCatalog;

  AdaptiveFlywheelModelProjection? model(String modelId) {
    for (final model in models) {
      if (model.id == modelId) return model;
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AdaptiveFlywheelAgentProjection &&
          other.id == id &&
          other.displayName == displayName &&
          samePresentationList(other.models, models) &&
          other.refreshingModelCatalog == refreshingModelCatalog;

  @override
  int get hashCode => Object.hash(
    id,
    displayName,
    Object.hashAll(models),
    refreshingModelCatalog,
  );
}

final class AdaptiveFlywheelAssistantProjection {
  const AdaptiveFlywheelAssistantProjection({
    required this.conversationId,
    required this.membershipId,
    required this.agentId,
    required this.modelId,
    required this.reasoningEffort,
    required this.profileRevision,
    required this.loading,
    required this.saving,
  });

  const AdaptiveFlywheelAssistantProjection.empty()
    : conversationId = '',
      membershipId = '',
      agentId = '',
      modelId = '',
      reasoningEffort = '',
      profileRevision = 0,
      loading = false,
      saving = false;

  final String conversationId;
  final String membershipId;
  final String agentId;
  final String modelId;
  final String reasoningEffort;
  final int profileRevision;
  final bool loading;
  final bool saving;

  bool get available => conversationId.isNotEmpty;

  AdaptiveFlywheelAssistantProjection copyWith({
    String? conversationId,
    String? membershipId,
    String? agentId,
    String? modelId,
    String? reasoningEffort,
    int? profileRevision,
    bool? loading,
    bool? saving,
  }) => AdaptiveFlywheelAssistantProjection(
    conversationId: conversationId ?? this.conversationId,
    membershipId: membershipId ?? this.membershipId,
    agentId: agentId ?? this.agentId,
    modelId: modelId ?? this.modelId,
    reasoningEffort: reasoningEffort ?? this.reasoningEffort,
    profileRevision: profileRevision ?? this.profileRevision,
    loading: loading ?? this.loading,
    saving: saving ?? this.saving,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AdaptiveFlywheelAssistantProjection &&
          other.conversationId == conversationId &&
          other.membershipId == membershipId &&
          other.agentId == agentId &&
          other.modelId == modelId &&
          other.reasoningEffort == reasoningEffort &&
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
    profileRevision,
    loading,
    saving,
  );
}

final class AdaptiveFlywheelProjection {
  AdaptiveFlywheelProjection({
    required Iterable<AdaptiveFlywheelDefinitionProjection> definitions,
    required this.selectedRevision,
    required this.inspection,
    required Iterable<AdaptiveFlywheelAgentProjection> callableAgents,
    required this.assistant,
    required this.busy,
    required this.error,
  }) : definitions = immutablePresentationList(definitions),
       callableAgents = immutablePresentationList(callableAgents);

  factory AdaptiveFlywheelProjection.empty() => AdaptiveFlywheelProjection(
    definitions: const [],
    selectedRevision: '',
    inspection: null,
    callableAgents: const [],
    assistant: const AdaptiveFlywheelAssistantProjection.empty(),
    busy: false,
    error: '',
  );

  final List<AdaptiveFlywheelDefinitionProjection> definitions;
  final String selectedRevision;
  final AdaptiveFlywheelInspectionProjection? inspection;
  final List<AdaptiveFlywheelAgentProjection> callableAgents;
  final AdaptiveFlywheelAssistantProjection assistant;
  final bool busy;
  final String error;

  AdaptiveFlywheelAgentProjection? agent(String agentId) {
    for (final agent in callableAgents) {
      if (agent.id == agentId) return agent;
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AdaptiveFlywheelProjection &&
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
