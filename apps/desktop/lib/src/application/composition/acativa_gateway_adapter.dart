import 'package:licoup/src/application/features/agents/contracts/acativa_gateway.dart';
import 'package:licoup/src/backend/features/agents/services/acativa_service.dart';
import 'package:licoup/src/contracts/agent_command_runner.dart';

final class AcativaGatewayAdapter implements AcativaGateway {
  const AcativaGatewayAdapter({required this.service, required this.runner});

  final AcativaService service;
  final AgentCommandRunner runner;

  @override
  Future<Object?> execute(Map<String, dynamic> request) =>
      service.execute(runner, request);
}
