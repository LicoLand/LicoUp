part of 'future_client_controller.dart';

extension FutureClientAgentUsageActions on FutureClientController {
  AgentUsageAgentSummary? get selectedAgentUsage {
    final agentId = selectedConversationAgentId;
    if (agentId.isEmpty) {
      return null;
    }
    return agentUsageReport?.agent(agentId);
  }

  Future<void> scanAgentUsage({bool observeNetwork = false}) async {
    if (isScanningAgentUsage || isObservingAgentNetwork) {
      return;
    }
    isScanningAgentUsage = !observeNetwork;
    isObservingAgentNetwork = observeNetwork;
    lastError = '';
    statusCaption = 'Agent usage';
    statusMessage = observeNetwork
        ? 'Observing local agent process traffic.'
        : 'Scanning local agent usage.';
    _notifyStateChanged();
    try {
      final report = await agentUsageService.scan(
        agentService: agentService,
        observeMs: observeNetwork ? 1500 : 0,
      );
      agentUsageReport = report;
      agentUsageReports = [
        report,
        ...agentUsageReports,
      ].take(10).toList(growable: false);
      statusMessage =
          'Scanned ${report.agentCount} agents and ${report.totalTokens} tokens.';
    } catch (error) {
      debugPrint('Failed to scan agent usage: $error');
      lastError = error.toString();
      statusMessage = 'Agent usage scan failed.';
    } finally {
      isScanningAgentUsage = false;
      isObservingAgentNetwork = false;
      _notifyStateChanged();
    }
  }

  Future<void> loadAgentUsageReports({int limit = 10}) async {
    if (isScanningAgentUsage || isObservingAgentNetwork) {
      return;
    }
    isScanningAgentUsage = true;
    lastError = '';
    statusCaption = 'Agent usage';
    _notifyStateChanged();
    try {
      agentUsageReports = await agentUsageService.reports(
        agentService: agentService,
        limit: limit,
      );
      if (agentUsageReports.isNotEmpty) {
        agentUsageReport = agentUsageReports.first;
      }
      statusMessage = 'Loaded ${agentUsageReports.length} usage reports.';
    } catch (error) {
      debugPrint('Failed to load agent usage reports: $error');
      lastError = error.toString();
      statusMessage = 'Agent usage reports failed to load.';
    } finally {
      isScanningAgentUsage = false;
      _notifyStateChanged();
    }
  }
}
