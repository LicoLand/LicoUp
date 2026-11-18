import 'package:licoup/src/application/features/agents/contracts/provider_quota_gateway.dart';
import 'package:licoup/src/contracts/agent_command_runner.dart';
import 'package:licoup/src/contracts/provider_quota_models.dart';

/// Composition adapter over the existing stdio bridge: runs the fixed
/// `provider-quota snapshot` command path registered beside `agent-usage`.
final class ProviderQuotaGatewayAdapter implements ProviderQuotaGateway {
  const ProviderQuotaGatewayAdapter({required this.runner});

  final AgentCommandRunner runner;

  @override
  Future<ProviderQuotaSnapshotReport> snapshot({
    String agentId = '',
    bool forceRefresh = false,
  }) async {
    final args = ['provider-quota', 'snapshot'];
    if (agentId.trim().isNotEmpty) {
      args.addAll(['--agent', agentId.trim()]);
    }
    if (forceRefresh) {
      args.add('--force-refresh');
    }
    final output = await runner.runCli(args);
    return ProviderQuotaSnapshotReport.fromJson(output);
  }
}
