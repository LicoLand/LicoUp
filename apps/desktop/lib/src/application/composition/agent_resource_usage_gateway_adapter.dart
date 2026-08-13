import 'package:licoup/src/application/features/settings/contracts/agent_resource_usage_gateway.dart';
import 'package:licoup/src/contracts/agent_command_runner.dart';
import 'package:licoup/src/contracts/agent_resource_usage_models.dart';

final class AgentResourceUsageGatewayAdapter
    implements AgentResourceUsageGateway {
  const AgentResourceUsageGatewayAdapter({required this.runner});

  final AgentCommandRunner runner;

  @override
  Future<AgentResourceUsageReport> scan() async {
    final output = await runner.runCli(['resource-usage', 'scan']);
    final report = AgentResourceUsageReport.fromJson(output);
    if (report.schemaVersion != AgentResourceUsageReport.currentSchemaVersion) {
      throw const FormatException('Unsupported agent resource usage envelope.');
    }
    return report;
  }
}
