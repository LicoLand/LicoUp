import 'package:licoup/src/application/features/agents/contracts/adaptive_flywheel_gateway.dart';
import 'package:licoup/src/backend/features/agents/services/adaptive_flywheel_service.dart';
import 'package:licoup/src/contracts/agent_command_runner.dart';

final class AdaptiveFlywheelGatewayAdapter implements AdaptiveFlywheelGateway {
  const AdaptiveFlywheelGatewayAdapter({
    required this.service,
    required this.runner,
  });

  final AdaptiveFlywheelService service;
  final AgentCommandRunner runner;

  @override
  Future<Object?> execute(Map<String, dynamic> request) =>
      service.execute(runner, request);
}
