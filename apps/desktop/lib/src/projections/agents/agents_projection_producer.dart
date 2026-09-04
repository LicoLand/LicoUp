import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/application/features/agents/adaptive_flywheel/adaptive_flywheel_controller.dart';
import 'package:licoup/src/application/features/agents/adaptive_flywheel/adaptive_flywheel_target_catalog.dart';
import 'package:licoup/src/contracts/adaptive_flywheel_models.dart';
import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/agent_product_identity.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/application/state/application_signal.dart';
import 'package:licoup/src/presentation/agents/adaptive_flywheel_projection.dart';
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
    required AdaptiveFlywheelController adaptiveFlywheel,
  }) : _controller = controller,
       _adaptiveFlywheel = adaptiveFlywheel,
       _current = _read(
         controller,
         adaptiveFlywheel,
         const AdaptiveFlywheelAssistantProjection.empty(),
       ) {
    _subscriptions = <StreamSubscription<ApplicationChange>>[
      controller.targetController.changes.listen(_handleChange),
      adaptiveFlywheel.changes.listen(_handleChange),
      controller.conversationPresentationSignals.structureChanges.listen(
        _handleChange,
      ),
      controller.conversationPresentationSignals.activeChanges.listen(
        _handleChange,
      ),
    ];
  }

  final ClientController _controller;
  final AdaptiveFlywheelController _adaptiveFlywheel;
  late final List<StreamSubscription<ApplicationChange>> _subscriptions;
  final StreamController<ProjectionUpdate<AgentsProjection>> _changes =
      StreamController<ProjectionUpdate<AgentsProjection>>.broadcast(
        sync: true,
      );
  AgentsProjection _current;
  AdaptiveFlywheelAssistantProjection _assistant =
      const AdaptiveFlywheelAssistantProjection.empty();
  bool _closed = false;

  @override
  AgentsProjection get current => _current;

  @override
  Stream<ProjectionUpdate<AgentsProjection>> get changes => _changes.stream;

  AdaptiveFlywheelAgentProjection? callableAgent(String agentId) =>
      _current.adaptiveFlywheel.agent(agentId);

  void setAssistantProfile(
    AdaptiveFlywheelAssistantProjection assistant, {
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
    final next = _read(_controller, _adaptiveFlywheel, _assistant);
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
    AdaptiveFlywheelController adaptiveFlywheel,
    AdaptiveFlywheelAssistantProjection assistant,
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
    final adaptiveProjection = AdaptiveFlywheelProjection(
      definitions: [
        for (final definition in adaptiveFlywheel.definitions)
          AdaptiveFlywheelDefinitionProjection(
            id: definition.id,
            name: definition.name,
            version: definition.version,
            revision: definition.revisionDigest,
            authorized: definition.authorized,
          ),
      ],
      selectedRevision: adaptiveFlywheel.selectedRevision,
      inspection: _inspectionProjection(adaptiveFlywheel.inspection),
      callableAgents: callableAgents,
      assistant: _assistantProjection(controller, callableAgents, assistant),
      busy: adaptiveFlywheel.busy,
      error: adaptiveFlywheel.error,
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
      adaptiveFlywheel: adaptiveProjection,
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

  static AdaptiveFlywheelAgentProjection _agentProjection(
    ClientController controller,
    TargetCandidate target,
  ) {
    final groups = agentOrchestrationCommanderModelGroups(target);
    final providerByModel = <String, AgentOrchestrationModelGroup>{
      for (final group in groups)
        for (final model in group.models) model: group,
    };
    return AdaptiveFlywheelAgentProjection(
      id: target.target,
      displayName: agentProductLabel(
        target.label.trim().isEmpty ? target.target : target.label,
      ),
      models: [
        for (final model in agentOrchestrationCommanderModels(target))
          AdaptiveFlywheelModelProjection(
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
      refreshingModelCatalog: controller.isRefreshingNativeModelCatalog(
        target.target,
      ),
    );
  }

  static AdaptiveFlywheelInspectionProjection? _inspectionProjection(
    AdaptiveFlywheelInspection? inspection,
  ) {
    if (inspection == null) return null;
    return AdaptiveFlywheelInspectionProjection(
      status: inspection.status,
      currentStates: inspection.currentStates,
      neighborStates: inspection.neighborStates,
      allowedOperations: inspection.allowedOperations,
      assignments: [
        for (final slot in inspection.slots)
          for (final binding in inspection.bindings[slot.id] ?? const [])
            AdaptiveFlywheelAssignmentProjection(
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
          AdaptiveFlywheelSlotProjection(
            id: slot.id,
            kind: slot.kind,
            label: slot.label,
            required: slot.required,
            entry: slot.entry,
          ),
      ],
      states: [
        for (final state in inspection.states)
          AdaptiveFlywheelGraphStateProjection(
            id: state.id,
            kind: state.kind,
            label: state.label,
          ),
      ],
      edges: [
        for (final edge in inspection.edges)
          AdaptiveFlywheelGraphEdgeProjection(
            from: edge.from,
            to: edge.to,
            event: edge.event,
            guardLabel: edge.guardLabel,
          ),
      ],
      initialState: inspection.initialState,
      diagnosticCode: inspection.diagnosticCode,
    );
  }

  static AdaptiveFlywheelAssistantProjection _assistantProjection(
    ClientController controller,
    List<AdaptiveFlywheelAgentProjection> agents,
    AdaptiveFlywheelAssistantProjection assistant,
  ) {
    final conversation =
        controller.clientConversationController.selectedConversation;
    if (conversation == null || !conversation.group) {
      return const AdaptiveFlywheelAssistantProjection.empty();
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
    return AdaptiveFlywheelAssistantProjection(
      conversationId: conversation.id,
      membershipId: membership?.id ?? '',
      agentId: agentId,
      modelId: model?.id ?? '',
      reasoningEffort: model?.defaultReasoningEffort ?? '',
      profileRevision: 0,
      loading: false,
      saving: false,
    );
  }

  static AdaptiveFlywheelAgentProjection? _findAgent(
    List<AdaptiveFlywheelAgentProjection> agents,
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
