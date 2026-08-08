import 'package:licoup/src/contracts/agent_command_runner.dart';
import 'package:licoup/src/contracts/client_update_models.dart';

abstract interface class ClientUpdateGateway {
  Future<bool> autoDownloadOverWifiEnabled();

  Future<void> setAutoDownloadOverWifiEnabled(bool enabled);

  Future<bool> isWifiConnected();

  Future<ClientUpdateStatus> status({
    required AgentCommandRunner agentService,
    String channel = 'stable',
  });

  Future<ClientUpdateRemoteCheck> check({
    required AgentCommandRunner agentService,
    String channel = 'stable',
  });

  Future<ClientUpdateStatus> download({
    required AgentCommandRunner agentService,
    required String manifestPath,
    required String publicKeysPath,
    required String artifactUrl,
    required int expectedBytes,
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

  Future<ClientUpdateStatus> apply({
    required AgentCommandRunner agentService,
    required String manifestPath,
    required String publicKeysPath,
    String channel = 'stable',
    String revocationPath = '',
    String stagingRoot = '',
  });
}

final class ClientUpdateRemoteCheck {
  const ClientUpdateRemoteCheck({
    required this.status,
    required this.manifestPath,
    required this.publicKeysPath,
    required this.artifactUrl,
  });

  final ClientUpdateStatus status;
  final String manifestPath;
  final String publicKeysPath;
  final String artifactUrl;
}
