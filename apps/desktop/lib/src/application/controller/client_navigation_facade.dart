import 'dart:async';

import 'package:flutter/widgets.dart';

import 'package:licoup/src/application/controller/client_agent_usage_facade.dart';
import 'package:licoup/src/application/controller/client_conversation_facade.dart';
import 'package:licoup/src/application/controller/client_mobile_relay_facade.dart';
import 'package:licoup/src/application/controller/client_presentation_facade.dart';
import 'package:licoup/src/application/controller/client_skill_hub_facade.dart';
import 'package:licoup/src/application/controller/client_target_facade.dart';
import 'package:licoup/src/application/features/agents/workspace/agent_workspace_coordinator.dart';
import 'package:licoup/src/application/features/agents/conversation/conversation_refresh_controller.dart';
import 'package:licoup/src/application/features/agents/conversation/conversation_session_controller.dart';
import 'package:licoup/src/application/features/agents/policy/conversation_refresh_policy.dart';
import 'package:licoup/src/application/features/navigation/controller/client_navigation_controller.dart';
import 'package:licoup/src/application/features/navigation/controller/client_section_preload_controller.dart';
import 'package:licoup/src/application/features/targets/policy/target_policy.dart';
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
        ClientTargetFacade {
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
    ClientSection.agents: () async {
      await Future.wait<void>([
        scanTargets(showProgress: false, surfaceErrors: true),
        clientConversationController.initialize(),
      ]);
    },
    ClientSection.monitoring: () => ensureAgentUsageLoadedAndFresh(limit: 20),
    ClientSection.skillHub: () =>
        refreshSkillHub(selectedConversationAgentId, showProgress: false),
    ClientSection.mobileRelay: () =>
        refreshSecureMeshStatus(authorize: false, showProgress: false),
  };

  void clientEnterAgentsSection() {
    var selectionChanged = false;
    if (!mobileClientRuntimePlatform && selectedConversationAgentId.isEmpty) {
      // Section entry retries the persisted selection after target discovery.
      // A fresh desktop install deliberately remains unselected.
      selectDefaultConversationAgent();
      selectionChanged = selectedConversationAgentId.isNotEmpty;
    }
    if (selectionChanged) notifyConversationStructureChanged();
    if (scannedTargets.isEmpty) unawaited(scanTargets());
  }

  /// Shows the desktop Welcome surface without replacing the persisted
  /// last-used conversation that should still be restored on the next launch.
  void showConversationWelcomePage() {
    if (selectedConversationAgentId.isEmpty &&
        clientConversationController.selectedConversationId.isEmpty) {
      return;
    }
    lastUsedConversationRestoreApplied = true;
    selectedConversationAgentId = '';
    clientConversationController.clearSelection();
    conversationAttentionContextChanged(immediateActive: false);
    notifyConversationStructureChanged();
    notifyClientStateChanged();
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
    // Relaunch restores the conversation the user last worked in. The restore
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
    // Desktop starts on the Welcome surface when there is no persisted
    // conversation. Mobile still needs one target selected for its compact
    // navigation flow.
    if (!mobileClientRuntimePlatform) {
      return;
    }
    final visibleTargets = scannedTargets
        .where((target) => target.isConversationAgent)
        .toList(growable: false);
    if (visibleTargets.isEmpty) {
      abandonNewConversationDraft(selectedConversationAgentId);
      selectedConversationAgentId = '';
      stopConversationRefreshScheduling();
      return;
    }
    if (selectedConversationAgentId.isEmpty ||
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
    return targetController.orderedConversationTargets(targets);
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
