import 'package:licoup/src/contracts/agent_resource_usage_models.dart';

abstract interface class AgentResourceUsageGateway {
  Future<AgentResourceUsageReport> scan();
}
