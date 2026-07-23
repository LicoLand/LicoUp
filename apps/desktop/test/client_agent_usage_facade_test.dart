import 'package:flutter_client/src/application/controller/client_agent_usage_facade.dart';
import 'package:flutter_client/src/application/features/agents/contracts/agent_usage_gateway.dart';
import 'package:flutter_client/src/application/features/agents/controller/agent_usage_controller.dart';
import 'package:flutter_client/src/contracts/agent_usage_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('usage facade only projects the dedicated usage controller state', () {
    final host = _UsageFacadeHost();
    addTearDown(host.dispose);
    final usage = AgentUsageAgentSummary(
      agentId: 'local-agent',
      label: 'Local agent',
      status: 'ready',
      history: const {'sessionCount': 1, 'totalTokens': 42},
      confidence: 'high',
    );
    final report = AgentUsageReport.fromAgents(
      generatedAt: '2026-07-15T00:00:00Z',
      agents: [usage],
    );

    host.agentUsageReport = report;
    host.agentUsageReports = [report];

    expect(host.agentUsageReport?.totalTokens, report.totalTokens);
    expect(host.agentUsageReport?.agent('local-agent')?.totalTokens, 42);
    expect(host.agentUsageReports, [report]);
    expect(host.selectedAgentUsage?.totalTokens, 42);
    expect(host.isScanningAgentUsage, isFalse);
  });
}

final class _UsageFacadeHost with ClientAgentUsageFacade {
  _UsageFacadeHost() {
    agentUsageController = AgentUsageController(
      gateway: _NoopUsageGateway(),
      selectedAgentId: () => 'local-agent',
      onStatus:
          ({
            required chinese,
            required english,
            required caption,
            errorCode = '',
          }) {},
    );
  }

  @override
  late final AgentUsageController agentUsageController;

  void dispose() => agentUsageController.dispose();
}

final class _NoopUsageGateway implements AgentUsageGateway {
  @override
  Future<List<AgentUsageReport>> reports({int limit = 10}) async => const [];

  @override
  Future<AgentUsageReport> scan({
    String agentId = '',
    bool forceRefresh = false,
    int historyDays = 90,
  }) async => AgentUsageReport.fromAgents(
    generatedAt: '2026-07-15T00:00:00Z',
    agents: const [],
  );
}
