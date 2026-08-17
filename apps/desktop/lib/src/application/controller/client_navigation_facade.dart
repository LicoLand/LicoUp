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
import 'package:licoup/src/application/features/navigation/controller/client_current_view_tracker.dart';
import 'package:licoup/src/application/features/navigation/controller/client_section_preload_controller.dart';
import 'package:licoup/src/application/features/targets/policy/target_policy.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/contracts/presentation/client_current_view.dart';
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
  bool _currentConversationViewRestoreApplied = false;
  bool _applyingCurrentConversationViewRestore = false;

  ClientNavigationController get navigationController;
  ClientSectionPreloadController get sectionPreloadController;
  ClientCurrentViewTracker get currentViewTracker;
  ClientCurrentViewStore get currentViewStore;
  bool get mobileClientRuntimePlatform;

  ClientSection get currentSection => navigationController.currentSection;
  set currentSection(ClientSection value) {
    navigationController.replaceCurrentSection(value);
  }

  void selectSection(ClientSection section) {
    navigationController.select(section);
    sectionPreloadController.prioritizeSection(section);
    conversationAttentionContextChanged();
    if (section == ClientSection.agents) {
      if (_currentConversationViewRestoreApplied) {
        _recordCurrentConversationView();
      } else {
        unawaited(applyCurrentConversationViewRestore());
      }
    } else {
      final current =
          currentViewTracker.current ??
          _currentConversationView(section: ClientSection.agents);
      currentViewTracker.record(current.withSection(section));
    }
    notifyClientStateChanged();
  }

  Future<void> loadCurrentViewRestore() async {
    await currentViewTracker.load(
      store: currentViewStore,
      portableData: agentWorkspacePortableData,
    );
    final restored = currentViewTracker.current;
    if (restored != null) {
      currentSection = restored.section;
    }
  }

  /// Default per-section background preload work, resolved at bootstrap.
  /// Quiet variants keep background loading off the visible status line.
  Map<ClientSection, Future<void> Function()> resolveSectionPreloadTasks() => {
    ClientSection.agents: () async {
      await Future.wait<void>([
        scanTargets(showProgress: false, surfaceErrors: true),
        clientConversationController.initialize(),
      ]);
      await applyCurrentConversationViewRestore();
    },
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
    unawaited(applyCurrentConversationViewRestore());
    if (scannedTargets.isEmpty) unawaited(scanTargets());
  }

  /// Shows Welcome and makes it the globally tracked current interface.
  void showConversationWelcomePage() {
    _currentConversationViewRestoreApplied = true;
    _applyingCurrentConversationViewRestore = true;
    try {
      selectedConversationAgentId = '';
      clientConversationController.clearSelection();
    } finally {
      _applyingCurrentConversationViewRestore = false;
    }
    currentViewTracker.record(
      ClientCurrentView.welcome(section: currentSection),
    );
    conversationAttentionContextChanged(immediateActive: false);
    notifyConversationStructureChanged();
    notifyClientStateChanged();
  }

  void clientEnterMonitoringSection() {
    if (!mobileClientRuntimePlatform) {
      agentUsageController.acquirePollingOwner(_navigationUsagePollingOwner);
      unawaited(agentUsageController.ensureLoadedAndFresh(limit: 20));
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
    // Relaunch restores the global current-view snapshot before any default.
    if (_tryRestoreCurrentAgentView()) {
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

  @override
  void agentWorkspaceRecordCurrentAgentView() {
    if (_applyingCurrentConversationViewRestore ||
        currentSection != ClientSection.agents) {
      return;
    }
    _currentConversationViewRestoreApplied = true;
    final agentId = selectedConversationAgentId.trim();
    if (agentId.isEmpty) {
      _recordCurrentConversationView();
      return;
    }
    currentViewTracker.record(
      ClientCurrentView.agent(
        section: currentSection,
        agentId: agentId,
        sessionId: selectedConversationSessionId.trim(),
      ),
    );
  }

  void recordCurrentGroupConversationView(String conversationId) {
    if (_applyingCurrentConversationViewRestore ||
        currentSection != ClientSection.agents) {
      return;
    }
    _currentConversationViewRestoreApplied = true;
    final normalized = conversationId.trim();
    if (normalized.isEmpty) {
      _recordCurrentConversationView();
      return;
    }
    currentViewTracker.record(
      ClientCurrentView.group(
        section: currentSection,
        conversationId: normalized,
      ),
    );
  }

  Future<bool> applyCurrentConversationViewRestore() async {
    if (_currentConversationViewRestoreApplied || !currentViewTracker.loaded) {
      return false;
    }
    final restored = currentViewTracker.current;
    if (restored == null ||
        restored.conversationKind == ClientConversationViewKind.welcome) {
      _currentConversationViewRestoreApplied = true;
      return false;
    }
    if (restored.conversationKind == ClientConversationViewKind.agent) {
      return _tryRestoreCurrentAgentView();
    }

    await clientConversationController.initialize();
    if (_currentConversationViewRestoreApplied ||
        currentViewTracker.current != restored) {
      return false;
    }
    final conversationId = restored.groupConversationId;
    if (!clientConversationController.groupConversations.any(
      (conversation) => conversation.id == conversationId,
    )) {
      _currentConversationViewRestoreApplied = true;
      return false;
    }
    _applyingCurrentConversationViewRestore = true;
    try {
      selectedConversationAgentId = '';
      await clientConversationController.selectConversation(conversationId);
    } finally {
      _applyingCurrentConversationViewRestore = false;
    }
    _currentConversationViewRestoreApplied = true;
    notifyConversationStructureChanged();
    notifyClientStateChanged();
    return true;
  }

  bool _tryRestoreCurrentAgentView() {
    if (_currentConversationViewRestoreApplied || !currentViewTracker.loaded) {
      return false;
    }
    final restored = currentViewTracker.current;
    if (restored == null ||
        restored.conversationKind != ClientConversationViewKind.agent) {
      return false;
    }
    _applyingCurrentConversationViewRestore = true;
    late final bool applied;
    try {
      clientConversationController.clearSelection();
      applied = restoreCurrentAgentView(restored.agentId, restored.sessionId);
    } finally {
      _applyingCurrentConversationViewRestore = false;
    }
    if (applied) _currentConversationViewRestoreApplied = true;
    return applied;
  }

  ClientCurrentView _currentConversationView({required ClientSection section}) {
    final groupId = clientConversationController.selectedConversationId.trim();
    if (groupId.isNotEmpty) {
      return ClientCurrentView.group(section: section, conversationId: groupId);
    }
    final agentId = selectedConversationAgentId.trim();
    if (agentId.isNotEmpty) {
      return ClientCurrentView.agent(
        section: section,
        agentId: agentId,
        sessionId: selectedConversationSessionId.trim(),
      );
    }
    return ClientCurrentView.welcome(section: section);
  }

  void _recordCurrentConversationView() {
    if (_applyingCurrentConversationViewRestore) {
      return;
    }
    currentViewTracker.record(
      _currentConversationView(section: currentSection),
    );
  }
}
