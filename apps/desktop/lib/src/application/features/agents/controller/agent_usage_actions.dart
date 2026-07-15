part of 'package:flutter_client/src/application/controller/client_controller.dart';

extension ClientAgentUsageActions on ClientController {
  AgentUsageAgentSummary? get selectedAgentUsage {
    final agentId = selectedConversationAgentId;
    if (agentId.isEmpty) {
      return null;
    }
    return agentUsageReport?.agent(agentId);
  }

  List<AgentUsageAllowance> allowancesForAgent(String agentId) {
    final normalized = agentId.trim();
    if (normalized.isEmpty) {
      return const [];
    }
    final cached = agentAllowanceOverrides[normalized];
    if (cached != null) {
      return cached;
    }
    return agentUsageReport?.agent(normalized)?.allowances ?? const [];
  }

  Future<void> refreshAgentAllowances(String agentId) async {
    final normalized = agentId.trim();
    if (normalized.isEmpty ||
        _mobileClientRuntimePlatform ||
        _agentAllowanceRefreshes.contains(normalized)) {
      return;
    }
    _agentAllowanceRefreshes.add(normalized);
    try {
      final report = await agentUsageService.scan(
        agentService: agentService,
        agentId: normalized,
        allowancesOnly: true,
      );
      _syncAgentAllowanceOverrides(report, authoritativeAgentIds: {normalized});
      final taskId = _activeOrchestrationTaskId;
      if (taskId.isNotEmpty) {
        await _evaluateOrchestrationRoutingBoundary(
          taskId: taskId,
          trigger: 'usage-allowance-refresh',
        );
      }
    } catch (_) {
    } finally {
      _agentAllowanceRefreshes.remove(normalized);
      _notifyStateChanged();
    }
  }
}
