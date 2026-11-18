import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/presentation/agents/acativa_projection.dart';
import 'package:licoup/src/presentation/agents/agents_intent.dart';
import 'package:licoup/src/presentation/agents/agents_projection.dart';
import 'package:licoup/src/presentation/agents/agents_resources.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';

/// Narrow renderer-facing inputs for the agent catalog view.
final class AgentsCatalogInputs {
  const AgentsCatalogInputs({
    required this.scope,
    required this.targets,
    required this.selectedAgentId,
    required this.workingDirectoryLabel,
    required this.phase,
    required this.targetDetails,
    required this.mobileRuntime,
    required this.scanning,
    required this.adding,
    required this.acativa,
    this.notice,
  });

  factory AgentsCatalogInputs.fromProjection(AgentsProjection projection) =>
      AgentsCatalogInputs(
        scope: agentsPresentationScope,
        targets: projection.targets,
        selectedAgentId: projection.selectedAgentId,
        workingDirectoryLabel: projection.workingDirectoryLabel,
        phase: projection.phase,
        targetDetails: projection.targetDetails,
        mobileRuntime: projection.mobileRuntime,
        scanning: projection.scanning,
        adding: projection.adding,
        acativa: projection.acativa,
        notice: projection.notice,
      );

  final ResourceScope scope;
  final List<AgentTargetProjection> targets;
  final String selectedAgentId;
  final String workingDirectoryLabel;
  final PresentationPhase phase;
  final List<TargetCandidate> targetDetails;
  final bool mobileRuntime;
  final bool scanning;
  final bool adding;
  final AcativaProjection acativa;
  final PresentationNotice? notice;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AgentsCatalogInputs &&
          other.scope == scope &&
          samePresentationList(other.targets, targets) &&
          other.selectedAgentId == selectedAgentId &&
          other.workingDirectoryLabel == workingDirectoryLabel &&
          other.phase == phase &&
          samePresentationList(other.targetDetails, targetDetails) &&
          other.mobileRuntime == mobileRuntime &&
          other.scanning == scanning &&
          other.adding == adding &&
          other.acativa == acativa &&
          other.notice == notice;

  @override
  int get hashCode => Object.hash(
    scope,
    Object.hashAll(targets),
    selectedAgentId,
    workingDirectoryLabel,
    phase,
    Object.hashAll(targetDetails),
    mobileRuntime,
    scanning,
    adding,
    acativa,
    notice,
  );
}

/// Narrow renderer actions for the agent catalog. Every dispatch carries the
/// pinned originating scope so asynchronous failures stay attributable.
final class AgentsCatalogActions {
  const AgentsCatalogActions({
    required this.origin,
    required this.scanAgents,
    required this.selectAgent,
    required this.selectConversationSession,
    required this.selectGroupConversationSession,
    required this.startConversation,
    required this.addManualAgent,
    required this.togglePinned,
    required this.selectWorkingDirectory,
    required this.initializeAcativa,
    required this.importAcativaPackage,
    required this.selectAcativaDefinition,
    required this.saveAcativaActorBindings,
    required this.refreshAcativaModelCatalogs,
    required this.readAcativaAssistantProfile,
    required this.updateAcativaAssistantProfile,
  });

  factory AgentsCatalogActions.fromIntents(IntentSink<AgentsIntent> intents) {
    const origin = ActionOrigin(
      scope: agentsPresentationScope,
      resource: agentsCatalogResource,
    );
    final channel = CallbackActions<AgentsIntent>(
      origin: origin,
      onDispatch: (intent, _) => intents.send(intent),
    );
    return AgentsCatalogActions(
      origin: origin,
      scanAgents: ({bool showProgress = true, bool forceRescanKnown = true}) =>
          channel.dispatch(
            ScanAgents(
              showProgress: showProgress,
              forceRescanKnown: forceRescanKnown,
            ),
          ),
      selectAgent: (agentId) => channel.dispatch(SelectAgent(agentId)),
      selectConversationSession:
          (agentId, sessionId, {String nativeSessionId = ''}) =>
              channel.dispatch(
                SelectAgentConversationSession(
                  agentId: agentId,
                  sessionId: sessionId,
                  nativeSessionId: nativeSessionId,
                ),
              ),
      selectGroupConversationSession:
          (
            groupConversationId,
            agentId,
            sessionId, {
            String nativeSessionId = '',
          }) => channel.dispatch(
            SelectGroupAgentConversationSession(
              groupConversationId: groupConversationId,
              agentId: agentId,
              sessionId: sessionId,
              nativeSessionId: nativeSessionId,
            ),
          ),
      startConversation: (agentId) =>
          channel.dispatch(StartAgentConversation(agentId)),
      addManualAgent:
          (
            command, {
            String configPath = '',
            String binaryPath = '',
            String historyRoot = '',
            String location = 'local',
            Map<String, dynamic> runtimeConnection = const {},
          }) => channel.dispatch(
            AddManualAgent(
              command: command,
              configPath: configPath,
              binaryPath: binaryPath,
              historyRoot: historyRoot,
              location: location,
              runtimeConnection: runtimeConnection,
            ),
          ),
      togglePinned: (agentId) => channel.dispatch(ToggleAgentPinned(agentId)),
      selectWorkingDirectory: (path) =>
          channel.dispatch(SelectAgentWorkingDirectory(path)),
      initializeAcativa: ({String initialRevision = ''}) =>
          channel.dispatch(InitializeAcativa(initialRevision: initialRevision)),
      importAcativaPackage: (path) =>
          channel.dispatch(ImportAcativaPackage(path)),
      selectAcativaDefinition: (revision) =>
          channel.dispatch(SelectAcativaDefinition(revision)),
      saveAcativaActorBindings: (assignments) =>
          channel.dispatch(SaveAcativaActorBindings(assignments: assignments)),
      refreshAcativaModelCatalogs: (agentIds) =>
          channel.dispatch(RefreshAcativaModelCatalogs(agentIds: agentIds)),
      readAcativaAssistantProfile: () =>
          channel.dispatch(const ReadAcativaAssistantProfile()),
      updateAcativaAssistantProfile:
          ({
            required String agentId,
            required String modelId,
            required String reasoningEffort,
          }) => channel.dispatch(
            UpdateAcativaAssistantProfile(
              agentId: agentId,
              modelId: modelId,
              reasoningEffort: reasoningEffort,
            ),
          ),
    );
  }

  final ActionOrigin origin;
  final FutureOr<void> Function({bool showProgress, bool forceRescanKnown})
  scanAgents;
  final FutureOr<void> Function(String agentId) selectAgent;
  final FutureOr<void> Function(
    String agentId,
    String sessionId, {
    String nativeSessionId,
  })
  selectConversationSession;
  final FutureOr<void> Function(
    String groupConversationId,
    String agentId,
    String sessionId, {
    String nativeSessionId,
  })
  selectGroupConversationSession;
  final FutureOr<void> Function(String agentId) startConversation;
  final FutureOr<void> Function(
    String command, {
    String configPath,
    String binaryPath,
    String historyRoot,
    String location,
    Map<String, dynamic> runtimeConnection,
  })
  addManualAgent;
  final FutureOr<void> Function(String agentId) togglePinned;
  final FutureOr<void> Function(String path) selectWorkingDirectory;
  final FutureOr<void> Function({String initialRevision}) initializeAcativa;
  final FutureOr<void> Function(String path) importAcativaPackage;
  final FutureOr<void> Function(String revision) selectAcativaDefinition;
  final FutureOr<void> Function(Iterable<AcativaAssignmentIntent> assignments)
  saveAcativaActorBindings;
  final FutureOr<void> Function(Iterable<String> agentIds)
  refreshAcativaModelCatalogs;
  final FutureOr<void> Function() readAcativaAssistantProfile;
  final FutureOr<void> Function({
    required String agentId,
    required String modelId,
    required String reasoningEffort,
  })
  updateAcativaAssistantProfile;
}
