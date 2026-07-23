import 'package:flutter_client/src/application/features/agents/controller/agent_usage_controller.dart';
import 'package:flutter_client/src/contracts/agent_usage_models.dart';

mixin ClientAgentUsageFacade {
  AgentUsageController get agentUsageController;

  AgentUsageReport? get agentUsageReport => agentUsageController.report;

  set agentUsageReport(AgentUsageReport? value) {
    agentUsageController.replaceReport(value);
  }

  List<AgentUsageReport> get agentUsageReports => agentUsageController.reports;

  set agentUsageReports(List<AgentUsageReport> value) {
    agentUsageController.replaceReports(value);
  }

  bool get isScanningAgentUsage => agentUsageController.scanning;
  int get agentUsageHistoryDays => agentUsageController.historyDays;
  bool get hasFreshAgentUsageScanCoverage =>
      agentUsageController.hasFreshScanCoverage;

  AgentUsageAgentSummary? get selectedAgentUsage =>
      agentUsageController.selectedUsage;

  void startAgentUsagePolling({
    Duration interval = defaultAgentUsagePollingInterval,
  }) => agentUsageController.startPolling(interval: interval);

  void stopAgentUsagePolling() => agentUsageController.stopPolling();

  Future<void> setAgentUsageHistoryDays(int days) =>
      agentUsageController.setHistoryDays(days);

  Future<void> ensureAgentUsageLoadedAndFresh({int limit = 20}) =>
      agentUsageController.ensureLoadedAndFresh(limit: limit);

  Future<void> scanAgentUsage({
    bool forceRefresh = true,
    bool showProgress = true,
  }) => agentUsageController.scan(
    forceRefresh: forceRefresh,
    showProgress: showProgress,
  );

  Future<void> loadAgentUsageReports({
    int limit = 10,
    bool showProgress = true,
  }) => agentUsageController.loadReports(
    limit: limit,
    showProgress: showProgress,
  );
}
