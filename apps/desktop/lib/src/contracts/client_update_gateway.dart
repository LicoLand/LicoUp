import 'package:licoup/src/contracts/agent_command_runner.dart';
import 'package:licoup/src/contracts/client_update_models.dart';

abstract interface class ClientUpdateGateway {
  Future<ClientUpdateStatus> status({
    required AgentCommandRunner agentService,
    String channel = 'stable',
    String source = 'local',
    String repo = 'LicoLand/LicoUp',
    String stateRoot = '',
  });

  /// Checks a signed update manifest from a local file pair (local source) or
  /// from the latest GitHub release of `repo` (github source). For the github
  /// source the bundled public keys are used and `manifestPath` is ignored.
  Future<ClientUpdateStatus> check({
    required AgentCommandRunner agentService,
    String manifestPath = '',
    String publicKeysPath = '',
    String channel = 'stable',
    String revocationPath = '',
    String source = 'local',
    String repo = 'LicoLand/LicoUp',
    String stagingRoot = '',
    String stateRoot = '',
  });

  /// Stages the update artifact. Local source copies `sourcePath`; github
  /// source streams the signed artifact url from the cached manifest.
  Future<ClientUpdateStatus> download({
    required AgentCommandRunner agentService,
    String manifestPath = '',
    String publicKeysPath = '',
    String sourcePath = '',
    String channel = 'stable',
    String revocationPath = '',
    String source = 'local',
    String repo = 'LicoLand/LicoUp',
    String stagingRoot = '',
    String stateRoot = '',
  });

  Future<ClientUpdateStatus> verify({
    required AgentCommandRunner agentService,
    String manifestPath = '',
    String publicKeysPath = '',
    String channel = 'stable',
    String revocationPath = '',
    String source = 'local',
    String repo = 'LicoLand/LicoUp',
    String stagingRoot = '',
    String stateRoot = '',
  });

  Future<ClientUpdateStatus> apply({
    required AgentCommandRunner agentService,
    required bool execute,
    String manifestPath = '',
    String publicKeysPath = '',
    String channel = 'stable',
    String revocationPath = '',
    String source = 'local',
    String repo = 'LicoLand/LicoUp',
    String stagingRoot = '',
    String stateRoot = '',
  });

  Future<ClientUpdateStatus> rollback({
    required AgentCommandRunner agentService,
    String manifestPath = '',
    String publicKeysPath = '',
    String channel = 'stable',
    String revocationPath = '',
    String source = 'local',
    String repo = 'LicoLand/LicoUp',
    String stagingRoot = '',
    String stateRoot = '',
  });
}
