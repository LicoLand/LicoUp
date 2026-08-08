import 'package:licoup/src/application/features/agents/contracts/agent_usage_gateway.dart';
import 'package:licoup/src/backend/features/agents/services/agent_usage_service.dart';
import 'package:licoup/src/contracts/agent_command_runner.dart';

final class AgentUsageGatewayAdapter implements AgentUsageGateway {
  const AgentUsageGatewayAdapter({required this.service, required this.runner});

  final AgentUsageService service;
  final AgentCommandRunner runner;

  @override
  Future<AgentUsageReport> scan({
    String agentId = '',
    bool forceRefresh = false,
    int historyDays = 90,
  }) => service.scan(
    agentService: runner,
    agentId: agentId,
    forceRefresh: forceRefresh,
    historyDays: historyDays,
  );

  @override
  Future<List<AgentUsageReport>> reports({int limit = 10}) =>
      service.reports(agentService: runner, limit: limit);
}
