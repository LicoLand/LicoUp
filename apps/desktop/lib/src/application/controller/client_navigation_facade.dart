import 'dart:async';

import 'package:flutter/widgets.dart';

import 'package:licoup/src/application/controller/client_agent_usage_facade.dart';
import 'package:licoup/src/application/controller/client_conversation_facade.dart';
import 'package:licoup/src/application/controller/client_mobile_relay_facade.dart';
import 'package:licoup/src/application/controller/client_presentation_facade.dart';
import 'package:licoup/src/application/controller/client_skill_hub_facade.dart';
import 'package:licoup/src/application/controller/client_target_facade.dart';
import 'package:licoup/src/application/features/agents/workspace/agent_workspace_coordinator.dart';
import 'package:licoup/src/application/features/agents/orchestration/agent_orchestration_policy_controller.dart';
import 'package:licoup/src/application/features/agents/conversation/conversation_refresh_controller.dart';
import 'package:licoup/src/application/features/agents/conversation/conversation_session_controller.dart';
import 'package:licoup/src/application/features/agents/policy/conversation_refresh_policy.dart';
import 'package:licoup/src/application/features/navigation/controller/client_navigation_controller.dart';
import 'package:licoup/src/application/features/navigation/controller/client_section_preload_controller.dart';
import 'package:licoup/src/application/features/targets/policy/target_policy.dart';
import 'package:licoup/src/contracts/agent_orchestration_target.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/contracts/target_candidate.dart';

mixin ClientNavigationFacade
    on
        AgentWorkspaceCoordinator,
        AgentConversationSessionController,
        ConversationRefreshController,
        ClientConversationFacade,
        ClientPresentationFacade,
        ClientAgentUsageFacade,
        ClientMobileRelayFacade,
        ClientSkillHubFacade,
        ClientTargetFacade,
        AgentOrchestrationPolicyController {
  final Object _navigationUsagePollingOwner = Object();

  ClientNavigationController get navigationController;
  ClientSectionPreloadController get sectionPreloadController;
  bool get mobileClientRuntimePlatform;

  ClientSection get currentSection => navigationController.currentSection;
  set currentSection(ClientSection value) {
    navigationController.replaceCurrentSection(value);
  }

  void selectSection(ClientSection section) {
    navigationController.select(section);
    sectionPreloadController.prioritizeSection(section);
    conversationAttentionContextChanged();
    notifyClientStateChanged();
  }

  /// Default per-section background preload work, resolved at bootstrap.
  /// Quiet variants keep background loading off the visible status line.
  Map<ClientSection, Future<void> Function()> resolveSectionPreloadTasks() => {
    ClientSection.agents: () =>
        scanTargets(showProgress: false, surfaceErrors: true),
    ClientSection.monitoring: () => ensureAgentUsageLoadedAndFresh(limit: 20),
    ClientSection.skillHub: () =>
        refreshSkillHub(selectedConversationAgentId, showProgress: false),
    ClientSection.mobileRelay: () =>
        refreshSecureMeshStatus(authorize: false, showProgress: false),
  };

  void clientEnterAgentsSection() {
    var selectionChanged = false;
    if (!mobileClientRuntimePlatform && selectedConversationAgentId.isEmpty) {
      // Section entry must run the same restore/default path as a
      // targets-settled callback: otherwise the user first sees orchestration
      // and a later settle flips the selection to the persisted agent.
      selectDefaultConversationAgent();
      selectionChanged = selectedConversationAgentId.isNotEmpty;
    }
    if (selectionChanged) notifyConversationStructureChanged();
    if (scannedTargets.isEmpty) unawaited(scanTargets());
  }

  void clientEnterMonitoringSection() {
    if (!mobileClientRuntimePlatform) {
      agentUsageController.acquirePollingOwner(_navigationUsagePollingOwner);
    }
  }

  void clientExitMonitoringSection() {
    agentUsageController.releasePollingOwner(_navigationUsagePollingOwner);
  }

  void clientEnterMobileRelaySection() {
    unawaited(refreshSecureMeshStatus(authorize: false));
  }

  void updateConversationAttention({
    AppLifecycleState? lifecycleState,
    bool? viewFocused,
  }) => updateConversationAttentionState(
    lifecycleState: lifecycleState == null
        ? null
        : switch (lifecycleState) {
            AppLifecycleState.resumed => ConversationLifecyclePhase.resumed,
            AppLifecycleState.inactive => ConversationLifecyclePhase.inactive,
            AppLifecycleState.hidden => ConversationLifecyclePhase.hidden,
            AppLifecycleState.paused => ConversationLifecyclePhase.paused,
            AppLifecycleState.detached => ConversationLifecyclePhase.detached,
          },
    viewFocused: viewFocused,
  );

  Future<List<TargetCandidate>> discoverMobileRelayTargets({
    Map<String, dynamic>? pairingStatus,
  }) async {
    final status = await mobileRelayController.pairingStatusForTargetDiscovery(
      pairingStatus: pairingStatus,
    );
    return status == null
        ? const <TargetCandidate>[]
        : TargetPolicy.mobileRelayTargets(status);
  }

  void selectDefaultConversationAgent({bool preferDirectAgent = false}) {
    // Relaunch restores the conversation the user last worked in; the default
    // selection only applies when there is nothing to restore. The restore
    // validates the agent itself, so it wins over `preferDirectAgent` too.
    if (applyLastUsedConversationRestore()) {
      return;
    }
    // Only an absent selection is defaulted. An existing selection (the
    // user's active conversation) is preserved even when the agent is
    // temporarily missing from this scan's results: a transient probe failure
    // must not kick the user out of the conversation, and the selection
    // reconnects once the agent is discovered again.
    if (selectedConversationAgentId.isNotEmpty) {
      return;
    }
    final visibleTargets = scannedTargets
        .where((target) => target.isConversationAgent)
        .where((target) => !isAgentOrchestrationTargetId(target.target))
        .toList(growable: false);
    if (visibleTargets.isEmpty) {
      abandonNewConversationDraft(selectedConversationAgentId);
      selectedConversationAgentId = '';
      stopConversationRefreshScheduling();
      return;
    }
    if (!mobileClientRuntimePlatform &&
        orchestrationAvailable &&
        !preferDirectAgent) {
      if (selectedConversationAgentId.isEmpty ||
          isAgentOrchestrationTargetId(selectedConversationAgentId) ||
          !visibleTargets.any(
            (target) => target.target == selectedConversationAgentId,
          )) {
        selectedConversationAgentId = agentOrchestrationTargetId;
        return;
      }
    }
    if (selectedConversationAgentId.isEmpty ||
        isAgentOrchestrationTargetId(selectedConversationAgentId) ||
        !visibleTargets.any(
          (target) => target.target == selectedConversationAgentId,
        )) {
      selectedConversationAgentId = visibleTargets.first.target;
      beginNewConversationDraft(selectedConversationAgentId);
    }
  }

  List<TargetCandidate> orderedConversationTargets(
    Iterable<TargetCandidate> targets,
  ) {
    return targetController.orderedConversationTargets(
      targets,
      orchestrationTarget:
          mobileClientRuntimePlatform || !orchestrationAvailable
          ? null
          : agentOrchestrationTargetCandidate(
              label: clientStrings.defaultLabel,
            ),
    );
  }

  @override
  bool get agentWorkspaceMobileRuntime => mobileClientRuntimePlatform;

  @override
  ClientSection get agentWorkspaceCurrentSection =>
      navigationController.currentSection;

  @override
  void agentWorkspaceSelectDefaultConversationAgent({
    bool preferDirectAgent = false,
  }) => selectDefaultConversationAgent(preferDirectAgent: preferDirectAgent);
}
