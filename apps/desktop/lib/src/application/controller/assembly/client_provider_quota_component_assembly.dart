import 'package:licoup/src/application/composition/provider_quota_gateway_adapter.dart';
import 'package:licoup/src/application/features/agents/controller/provider_quota_controller.dart';
import 'package:licoup/src/platform/native_client/agent_service.dart';

final class ClientProviderQuotaComponentAssembly {
  ClientProviderQuotaComponentAssembly({required AgentService agentService})
    : controller = ProviderQuotaController(
        gateway: ProviderQuotaGatewayAdapter(runner: agentService),
      );

  final ProviderQuotaController controller;

  void dispose() => controller.dispose();
}
