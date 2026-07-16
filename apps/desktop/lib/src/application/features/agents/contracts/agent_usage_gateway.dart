import 'package:flutter_client/src/contracts/agent_usage_models.dart';

abstract interface class AgentUsageGateway {
  Future<AgentUsageReport> scan({
    String agentId = '',
    bool forceRefresh = false,
    int historyDays = 30,
  });

  Future<List<AgentUsageReport>> reports({int limit = 10});
}
