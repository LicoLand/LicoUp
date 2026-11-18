import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/application/features/agents/acativa/acativa_controller.dart';
import 'package:licoup/src/application/features/agents/acativa/acativa_target_catalog.dart';
import 'package:licoup/src/contracts/acativa_models.dart';
import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/presentation/agents/agent_product_identity.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/application/state/application_signal.dart';
import 'package:licoup/src/presentation/agents/acativa_projection.dart';
import 'package:licoup/src/presentation/agents/agents_projection.dart';
import 'package:licoup/src/projections/close_broadcast_controller.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';

/// Focused Agents read-side adapter. It observes only target and conversation
/// selection owners; the root orchestrator is never used as a notification
/// bus.
final class AgentsProjectionProducer
    implements ProjectionSource<AgentsProjection> {
  AgentsProjectionProducer(
    ClientController controller, {
    required AcativaController acativa,
  }) : _controller = controller,
       _acativa = acativa,
       _current = _read(
         controller,
         acativa,
         const AcativaAssistantProjection.empty(),
       ) {
    _subscriptions = <StreamSubscription<ApplicationChange>>[
      controller.targetController.changes.listen(_handleChange),
      acativa.changes.listen(_handleChange),
      controller.conversationPresentationSignals.structureChanges.listen(
        _handleChange,
      ),
      controller.conversationPresentationSignals.activeChanges.listen(
        _handleChange,
      ),
    ];
  }

  final ClientController _controller;
  final AcativaController _acativa;
  late final List<StreamSubscription<ApplicationChange>> _subscriptions;
  final StreamController<ProjectionUpdate<AgentsProjection>> _changes =
      StreamController<ProjectionUpdate<AgentsProjection>>.broadcast(
        sync: true,
      );
  AgentsProjection _current;
  AcativaAssistantProjection _assistant =
      const AcativaAssistantProjection.empty();
  bool _closed = false;

  @override
  AgentsProjection get current => _current;

  @override
  Stream<ProjectionUpdate<AgentsProjection>> get changes => _changes.stream;

  AcativaAgentProjection? callableAgent(String agentId) =>
      _current.acativa.agent(agentId);

  void setAssistantProfile(
    AcativaAssistantProjection assistant, {
    TraceContext? trace,
  }) {
    if (_closed || assistant == _assistant) return;
    _assistant = assistant;
    _emit(trace: trace);
  }

  void _handleChange(ApplicationChange change) {
    if (_closed) return;
    _emit(trace: _trace(change.cause));
  }

  void _emit({TraceContext? trace}) {
    final next = _read(_controller, _acativa, _assistant);
    if (next == _current) return;
    _current = next;
    _changes.add(ProjectionUpdate<AgentsProjection>(next, trace: trace));
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final subscription in _subscriptions.reversed) {
      await subscription.cancel();
    }
    await closeBroadcastController(_changes);
  }

  static AgentsProjection _read(
    ClientController controller,
    AcativaController acativa,
    AcativaAssistantProjection assistant,
  ) {
    final targets = controller.targetController.orderedConversationTargets(
      controller.targetController.targets.where(
        (target) => target.visibleInClient,
      ),
    );
    final callableAgents = [
      for (final target in agentOrchestrationCommanderTargets(targets))
        _agentProjection(controller, target),
    ];
    final adaptiveProjection = AcativaProjection(
      definitions: [
        for (final definition in acativa.definitions)
          AcativaDefinitionProjection(
            id: definition.id,
            name: definition.name,
            version: definition.version,
            revision: definition.revisionDigest,
            authorized: definition.authorized,
          ),
      ],
      selectedRevision: acativa.selectedRevision,
      inspection: _inspectionProjection(acativa.inspection),
      callableAgents: callableAgents,
      assistant: _assistantProjection(controller, callableAgents, assistant),
      busy: acativa.busy,
      error: acativa.error,
    );
    return AgentsProjection(
      targets: [
        for (final target in targets) _targetProjection(controller, target),
      ],
      targetDetails: targets,
      selectedAgentId: controller.selectedConversationAgentId,
      workingDirectoryLabel: controller.selectedConversationWorkingDirectory,
      phase: controller.targetController.isScanning
          ? PresentationPhase.loading
          : controller.targetController.lastErrorCode.isNotEmpty
          ? PresentationPhase.failed
          : PresentationPhase.ready,
      mobileRuntime: controller.mobileClientRuntimePlatform,
      scanning: controller.targetController.isScanning,
      adding: controller.targetController.isAdding,
      notice: controller.targetController.lastErrorCode.isEmpty
          ? null
          : PresentationNotice(
              id: 'agents-target-error',
              title: 'Agents',
              message: controller.targetController.lastErrorCode,
              severity: PresentationNoticeSeverity.error,
              reasonCode: controller.targetController.lastErrorCode,
            ),
      acativa: adaptiveProjection,
    );
  }

  static AgentTargetProjection _targetProjection(
    ClientController controller,
    TargetCandidate target,
  ) {
    final sessions =
        controller.conversationSessionsByAgent[target.target] ??
        controller.conversationSessionsByAgent[target.id] ??
        const <AgentConversationSession>[];
    AgentConversationSession? latest;
    var latestTime = 0;
    for (final session in sessions) {
      final time = _conversationSortTime(session);
      if (latest == null || time > latestTime) {
        latest = session;
        latestTime = time;
      }
    }
    return AgentTargetProjection(
      id: target.target,
      displayName: agentProductLabel(
        target.label.trim().isEmpty ? target.target : target.label,
      ),
      available: target.status != 'not-detected',
      pinned: controller.targetController.isConversationTargetPinned(
        target.target,
      ),
      capabilityLabel: target.conversationSendGateReason.isEmpty
          ? target.status
          : target.conversationSendGateReason,
      latestConversationPreview: (latest?.preview ?? '')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim(),
      latestConversationSortTimeMillis: latestTime,
    );
  }

  static int _conversationSortTime(AgentConversationSession session) =>
      (DateTime.tryParse(session.updatedAt) ??
              DateTime.tryParse(session.createdAt) ??
              DateTime.fromMillisecondsSinceEpoch(0, isUtc: true))
          .toUtc()
          .millisecondsSinceEpoch;

  static AcativaAgentProjection _agentProjection(
    ClientController controller,
    TargetCandidate target,
  ) {
    final groups = agentOrchestrationCommanderModelGroups(target);
    final providerByModel = <String, AgentOrchestrationModelGroup>{
      for (final group in groups)
        for (final model in group.models) model: group,
    };
    return AcativaAgentProjection(
      id: target.target,
      displayName: agentProductLabel(
        target.label.trim().isEmpty ? target.target : target.label,
      ),
      models: [
        for (final model in agentOrchestrationCommanderModels(target))
          AcativaModelProjection(
            id: model,
            label: agentOrchestrationModelDisplayName(target, model),
            providerId: providerByModel[model]?.providerId ?? '',
            providerLabel: providerByModel[model]?.providerLabel ?? '',
            reasoningEfforts: agentOrchestrationReasoningEffortsForModel(
              target,
              model,
            ),
            defaultReasoningEffort:
                agentOrchestrationDefaultReasoningEffortForModel(target, model),
          ),
      ],
      permissionModes: target.conversationPermissionModes,
      refreshingModelCatalog: controller.isRefreshingNativeModelCatalog(
        target.target,
      ),
    );
  }

  static AcativaInspectionProjection? _inspectionProjection(
    AcativaInspection? inspection,
  ) {
    if (inspection == null) return null;
    return AcativaInspectionProjection(
      status: inspection.status,
      modelDisplayNames: inspection.modelDisplayNames,
      currentStates: inspection.currentStates,
      neighborStates: inspection.neighborStates,
      allowedOperations: inspection.allowedOperations,
      assignments: [
        for (final slot in inspection.slots)
          for (final binding in inspection.bindings[slot.id] ?? const [])
            AcativaAssignmentProjection(
              slotId: binding.slotId,
              ordinal: binding.ordinal,
              agentId: binding.valueId,
              modelId: binding.model,
              reasoningEffort: binding.reasoningEffort,
              revision: binding.revision,
            ),
      ],
      slots: [
        for (final slot in inspection.slots)
          AcativaSlotProjection(
            id: slot.id,
            kind: slot.kind,
            label: slot.label,
            required: slot.required,
            entry: slot.entry,
          ),
      ],
      states: [
        for (final state in inspection.states)
          AcativaGraphStateProjection(
            id: state.id,
            kind: state.kind,
            label: state.label,
          ),
      ],
      edges: [
        for (final edge in inspection.edges)
          AcativaGraphEdgeProjection(
            from: edge.from,
            to: edge.to,
            event: edge.event,
            mode: edge.mode,
            guardLabel: edge.guardLabel,
          ),
      ],
      initialState: inspection.initialState,
      diagnosticCode: inspection.diagnosticCode,
    );
  }

  static AcativaAssistantProjection _assistantProjection(
    ClientController controller,
    List<AcativaAgentProjection> agents,
    AcativaAssistantProjection assistant,
  ) {
    final conversation =
        controller.clientConversationController.selectedConversation;
    if (conversation == null || !conversation.group) {
      return const AcativaAssistantProjection.empty();
    }
    if (assistant.conversationId == conversation.id) return assistant;
    final membership =
        conversation.assistantMembership ??
        (conversation.activeAgentMemberships.isEmpty
            ? null
            : conversation.activeAgentMemberships.first);
    final agentId = membership?.principal.agentId.trim().isNotEmpty == true
        ? membership!.principal.agentId.trim()
        : (agents.isEmpty ? '' : agents.first.id);
    final agent = _findAgent(agents, agentId);
    final model = agent?.models.firstOrNull;
    return AcativaAssistantProjection(
      conversationId: conversation.id,
      membershipId: membership?.id ?? '',
      agentId: agentId,
      modelId: model?.id ?? '',
      reasoningEffort: model?.defaultReasoningEffort ?? '',
      permissionMode: '',
      profileRevision: 0,
      loading: false,
      saving: false,
    );
  }

  static AcativaAgentProjection? _findAgent(
    List<AcativaAgentProjection> agents,
    String agentId,
  ) {
    for (final agent in agents) {
      if (agent.id == agentId) return agent;
    }
    return null;
  }
}

TraceContext? _trace(ApplicationCause? cause) =>
    cause?.traceId == null ? null : TraceContext(traceId: cause!.traceId);
