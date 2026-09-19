import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/presentation/agents/adaptive_flywheel_projection.dart';
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
    required this.adaptiveFlywheel,
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
        adaptiveFlywheel: projection.adaptiveFlywheel,
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
  final AdaptiveFlywheelProjection adaptiveFlywheel;
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
          other.adaptiveFlywheel == adaptiveFlywheel &&
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
    adaptiveFlywheel,
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
    required this.showWelcome,
    required this.selectConversationSession,
    required this.selectGroupConversationSession,
    required this.startConversation,
    required this.addManualAgent,
    required this.togglePinned,
    required this.selectWorkingDirectory,
    required this.initializeAdaptiveFlywheel,
    required this.importAdaptiveFlywheelPackage,
    required this.selectAdaptiveFlywheelDefinition,
    required this.saveAdaptiveFlywheelActorBindings,
    required this.refreshAdaptiveFlywheelModelCatalogs,
    required this.readAdaptiveFlywheelAssistantProfile,
    required this.updateAdaptiveFlywheelAssistantProfile,
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
      showWelcome: () => channel.dispatch(const ShowAgentsWelcome()),
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
      initializeAdaptiveFlywheel: ({String initialRevision = ''}) =>
          channel.dispatch(
            InitializeAdaptiveFlywheel(initialRevision: initialRevision),
          ),
      importAdaptiveFlywheelPackage: (path) =>
          channel.dispatch(ImportAdaptiveFlywheelPackage(path)),
      selectAdaptiveFlywheelDefinition: (revision) =>
          channel.dispatch(SelectAdaptiveFlywheelDefinition(revision)),
      saveAdaptiveFlywheelActorBindings: (assignments) => channel.dispatch(
        SaveAdaptiveFlywheelActorBindings(assignments: assignments),
      ),
      refreshAdaptiveFlywheelModelCatalogs: (agentIds) => channel.dispatch(
        RefreshAdaptiveFlywheelModelCatalogs(agentIds: agentIds),
      ),
      readAdaptiveFlywheelAssistantProfile: () =>
          channel.dispatch(const ReadAdaptiveFlywheelAssistantProfile()),
      updateAdaptiveFlywheelAssistantProfile:
          ({
            required String agentId,
            required String modelId,
            required String reasoningEffort,
          }) => channel.dispatch(
            UpdateAdaptiveFlywheelAssistantProfile(
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
  final FutureOr<void> Function() showWelcome;
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
  final FutureOr<void> Function({String initialRevision})
  initializeAdaptiveFlywheel;
  final FutureOr<void> Function(String path) importAdaptiveFlywheelPackage;
  final FutureOr<void> Function(String revision)
  selectAdaptiveFlywheelDefinition;
  final FutureOr<void> Function(
    Iterable<AdaptiveFlywheelAssignmentIntent> assignments,
  )
  saveAdaptiveFlywheelActorBindings;
  final FutureOr<void> Function(Iterable<String> agentIds)
  refreshAdaptiveFlywheelModelCatalogs;
  final FutureOr<void> Function() readAdaptiveFlywheelAssistantProfile;
  final FutureOr<void> Function({
    required String agentId,
    required String modelId,
    required String reasoningEffort,
  })
  updateAdaptiveFlywheelAssistantProfile;
}
