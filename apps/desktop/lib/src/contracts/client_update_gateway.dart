import 'package:flutter_client/src/contracts/agent_command_runner.dart';
import 'package:flutter_client/src/contracts/client_update_models.dart';

abstract interface class ClientUpdateGateway {
  Future<ClientUpdateStatus> status({
    required AgentCommandRunner agentService,
    String channel = 'stable',
  });

  Future<ClientUpdateStatus> check({
    required AgentCommandRunner agentService,
    required String manifestPath,
    required String publicKeysPath,
    String channel = 'stable',
    String revocationPath = '',
  });

  Future<ClientUpdateStatus> download({
    required AgentCommandRunner agentService,
    required String manifestPath,
    required String publicKeysPath,
    required String sourcePath,
    String channel = 'stable',
    String revocationPath = '',
    String stagingRoot = '',
  });

  Future<ClientUpdateStatus> verify({
    required AgentCommandRunner agentService,
    required String manifestPath,
    required String publicKeysPath,
    String channel = 'stable',
    String revocationPath = '',
    String stagingRoot = '',
  });

  Future<ClientUpdateStatus> applyDryRun({
    required AgentCommandRunner agentService,
    required String manifestPath,
    required String publicKeysPath,
    String channel = 'stable',
    String revocationPath = '',
    String stagingRoot = '',
  });
}
