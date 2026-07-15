part of 'package:flutter_client/src/application/controller/client_controller.dart';

extension ClientNavigationActions on ClientController {
  void selectSection(ClientSection section) {
    // Skill Hub is merged into the Extensions hub (mcpPlugins).
    final resolved = section == ClientSection.skillHub
        ? ClientSection.mcpPlugins
        : section;
    final nextSection = _mobileAllowedSection(resolved);
    var conversationSelectionChanged = false;
    if (nextSection == ClientSection.agents && !_mobileClientRuntimePlatform) {
      if (selectedConversationAgentId.isEmpty) {
        if (routingModuleAvailable) {
          selectedConversationAgentId = agentOrchestrationTargetId;
        } else {
          _selectDefaultConversationAgent(preferDirectAgent: true);
        }
        _preparingNewConversation = false;
        conversationSelectionChanged = selectedConversationAgentId.isNotEmpty;
      }
      if (selectedConversationIsOrchestration) {
        _syncAgentOrchestrationPolicy();
        _ensureOrchestrationConversationSession();
      }
    }
    if (currentSection == nextSection) {
      if (nextSection == ClientSection.mcpPlugins) {
        _startMcpPluginTargetPolling();
      }
      if (conversationSelectionChanged) {
        _notifyConversationStructureChanged();
      }
      _conversationAttentionContextChanged();
      _notifyStateChanged();
      return;
    }
    currentSection = nextSection;
    if (nextSection == ClientSection.mcpPlugins) {
      _startMcpPluginTargetPolling();
      unawaited(scanTargets());
    } else {
      _stopMcpPluginTargetPolling();
    }
    if (conversationSelectionChanged) {
      _notifyConversationStructureChanged();
    }
    _conversationAttentionContextChanged();
    _notifyStateChanged();
    if (nextSection == ClientSection.agents && scannedTargets.isEmpty) {
      unawaited(scanTargets());
    }
    if (!_mobileClientRuntimePlatform &&
        nextSection == ClientSection.monitoring) {
      startAgentUsagePolling();
    }
    if (!_mobileClientRuntimePlatform &&
        nextSection == ClientSection.localRuntime) {
      unawaited(refreshLocalRuntimeStatus());
    }
    if (nextSection == ClientSection.mobileRelay) {
      unawaited(refreshSecureMeshStatus(authorize: false));
    }
  }
}
