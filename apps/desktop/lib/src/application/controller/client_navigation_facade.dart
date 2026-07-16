import 'dart:async';

import 'package:flutter/widgets.dart';

import 'package:flutter_client/src/application/controller/client_agent_usage_facade.dart';
import 'package:flutter_client/src/application/controller/client_conversation_facade.dart';
import 'package:flutter_client/src/application/controller/client_mobile_relay_facade.dart';
import 'package:flutter_client/src/application/controller/client_presentation_facade.dart';
import 'package:flutter_client/src/application/controller/client_target_facade.dart';
import 'package:flutter_client/src/application/features/agents/workspace/agent_workspace_coordinator.dart';
import 'package:flutter_client/src/application/features/agents/conversation/conversation_refresh_controller.dart';
import 'package:flutter_client/src/application/features/agents/policy/conversation_refresh_policy.dart';
import 'package:flutter_client/src/application/features/navigation/controller/client_navigation_controller.dart';
import 'package:flutter_client/src/application/features/targets/policy/target_policy.dart';
import 'package:flutter_client/src/contracts/agent_orchestration_policy.dart';
import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/contracts/target_candidate.dart';

mixin ClientNavigationFacade
    on
        AgentWorkspaceCoordinator,
        ConversationRefreshController,
        ClientConversationFacade,
        ClientPresentationFacade,
        ClientAgentUsageFacade,
        ClientMobileRelayFacade,
        ClientTargetFacade {
  final Object _navigationUsagePollingOwner = Object();

  ClientNavigationController get navigationController;
  bool get mobileClientRuntimePlatform;

  ClientSection get currentSection => navigationController.currentSection;
  set currentSection(ClientSection value) {
    navigationController.replaceCurrentSection(value);
  }

  void selectSection(ClientSection section) {
    navigationController.select(section);
    conversationAttentionContextChanged();
    notifyClientStateChanged();
  }

  void clientEnterAgentsSection() {
    var selectionChanged = false;
    if (!mobileClientRuntimePlatform && selectedConversationAgentId.isEmpty) {
      if (routingModuleAvailable) {
        selectedConversationAgentId = agentOrchestrationTargetId;
      } else {
        selectDefaultConversationAgent(preferDirectAgent: true);
      }
      preparingNewConversation = false;
      selectionChanged = selectedConversationAgentId.isNotEmpty;
    }
    if (!mobileClientRuntimePlatform && selectedConversationIsOrchestration) {
      syncAgentOrchestrationPolicy();
      ensureOrchestrationConversationSession();
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
    final visibleTargets = scannedTargets
        .where((target) => target.isConversationAgent)
        .where((target) => !isAgentOrchestrationTargetId(target.target))
        .toList(growable: false);
    if (visibleTargets.isEmpty) {
      selectedConversationAgentId = '';
      preparingNewConversation = false;
      stopConversationRefreshScheduling();
      return;
    }
    if (!mobileClientRuntimePlatform &&
        routingModuleAvailable &&
        !preferDirectAgent) {
      if (selectedConversationAgentId.isEmpty ||
          isAgentOrchestrationTargetId(selectedConversationAgentId) ||
          !visibleTargets.any(
            (target) => target.target == selectedConversationAgentId,
          )) {
        selectedConversationAgentId = agentOrchestrationTargetId;
        preparingNewConversation = false;
        ensureOrchestrationConversationSession();
        return;
      }
    }
    if (selectedConversationAgentId.isEmpty ||
        isAgentOrchestrationTargetId(selectedConversationAgentId) ||
        !visibleTargets.any(
          (target) => target.target == selectedConversationAgentId,
        )) {
      selectedConversationAgentId = visibleTargets.first.target;
      preparingNewConversation = false;
    }
  }

  List<TargetCandidate> orderedConversationTargets(
    Iterable<TargetCandidate> targets,
  ) {
    return targetController.orderedConversationTargets(
      targets,
      orchestrationTarget:
          mobileClientRuntimePlatform || !routingModuleAvailable
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
