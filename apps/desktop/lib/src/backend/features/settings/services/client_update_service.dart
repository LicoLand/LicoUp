import 'package:licoup/src/contracts/agent_command_runner.dart';
import 'package:licoup/src/contracts/client_update_models.dart';
import 'package:licoup/src/contracts/client_update_gateway.dart';

export 'package:licoup/src/contracts/client_update_models.dart';

class ClientUpdateService implements ClientUpdateGateway {
  const ClientUpdateService();

  @override
  Future<ClientUpdateStatus> status({
    required AgentCommandRunner agentService,
    String channel = 'stable',
    String source = 'local',
    String repo = 'LicoLand/LicoUp',
    String stateRoot = '',
  }) async {
    final args = [
      'update',
      'status',
      '--channel',
      channel.trim().isEmpty ? 'stable' : channel.trim(),
      '--source',
      source.trim().isEmpty ? 'local' : source.trim(),
      '--repo',
      repo.trim().isEmpty ? 'LicoLand/LicoUp' : repo.trim(),
    ];
    _appendRoots(args, stateRoot: stateRoot);
    final output = await agentService.runCli(args);
    return ClientUpdateStatus.fromJson(output);
  }

  @override
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
  }) async {
    final github = source.trim() == 'github';
    final args = [
      'update',
      'check',
      '--channel',
      channel.trim().isEmpty ? 'stable' : channel.trim(),
      '--source',
      github ? 'github' : 'local',
      '--repo',
      repo.trim().isEmpty ? 'LicoLand/LicoUp' : repo.trim(),
    ];
    if (!github) {
      args
        ..addAll(['--manifest-path', manifestPath.trim()])
        ..addAll(['--public-keys-path', publicKeysPath.trim()]);
      if (revocationPath.trim().isNotEmpty) {
        args.addAll(['--revocation-path', revocationPath.trim()]);
      }
    }
    _appendRoots(args, stagingRoot: stagingRoot, stateRoot: stateRoot);
    final output = await agentService.runCli(args);
    return ClientUpdateStatus.fromJson(output);
  }

  @override
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
  }) async {
    final github = source.trim() == 'github';
    final args = [
      'update',
      'download',
      '--channel',
      channel.trim().isEmpty ? 'stable' : channel.trim(),
      '--source',
      github ? 'github' : 'local',
      '--repo',
      repo.trim().isEmpty ? 'LicoLand/LicoUp' : repo.trim(),
    ];
    if (!github) {
      args
        ..addAll(['--manifest-path', manifestPath.trim()])
        ..addAll(['--public-keys-path', publicKeysPath.trim()])
        ..addAll(['--source-path', sourcePath.trim()]);
      if (revocationPath.trim().isNotEmpty) {
        args.addAll(['--revocation-path', revocationPath.trim()]);
      }
    }
    _appendRoots(args, stagingRoot: stagingRoot, stateRoot: stateRoot);
    final output = await agentService.runCli(args);
    return ClientUpdateStatus.fromJson(output);
  }

  @override
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
  }) async {
    final github = source.trim() == 'github';
    final args = [
      'update',
      'verify',
      '--channel',
      channel.trim().isEmpty ? 'stable' : channel.trim(),
      '--source',
      github ? 'github' : 'local',
      '--repo',
      repo.trim().isEmpty ? 'LicoLand/LicoUp' : repo.trim(),
    ];
    if (!github) {
      args
        ..addAll(['--manifest-path', manifestPath.trim()])
        ..addAll(['--public-keys-path', publicKeysPath.trim()]);
      if (revocationPath.trim().isNotEmpty) {
        args.addAll(['--revocation-path', revocationPath.trim()]);
      }
    }
    _appendRoots(args, stagingRoot: stagingRoot, stateRoot: stateRoot);
    final output = await agentService.runCli(args);
    return ClientUpdateStatus.fromJson(output);
  }

  @override
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
  }) async {
    final github = source.trim() == 'github';
    final args = [
      'update',
      'apply',
      '--channel',
      channel.trim().isEmpty ? 'stable' : channel.trim(),
      '--source',
      github ? 'github' : 'local',
      '--repo',
      repo.trim().isEmpty ? 'LicoLand/LicoUp' : repo.trim(),
      '--execute',
      execute ? 'true' : 'false',
    ];
    if (!github) {
      args
        ..addAll(['--manifest-path', manifestPath.trim()])
        ..addAll(['--public-keys-path', publicKeysPath.trim()]);
      if (revocationPath.trim().isNotEmpty) {
        args.addAll(['--revocation-path', revocationPath.trim()]);
      }
    }
    _appendRoots(args, stagingRoot: stagingRoot, stateRoot: stateRoot);
    final output = await agentService.runCli(args);
    return ClientUpdateStatus.fromJson(output);
  }

  @override
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
  }) async {
    final github = source.trim() == 'github';
    final args = [
      'update',
      'rollback',
      '--channel',
      channel.trim().isEmpty ? 'stable' : channel.trim(),
      '--source',
      github ? 'github' : 'local',
      '--repo',
      repo.trim().isEmpty ? 'LicoLand/LicoUp' : repo.trim(),
    ];
    if (!github) {
      args
        ..addAll(['--manifest-path', manifestPath.trim()])
        ..addAll(['--public-keys-path', publicKeysPath.trim()]);
      if (revocationPath.trim().isNotEmpty) {
        args.addAll(['--revocation-path', revocationPath.trim()]);
      }
    }
    _appendRoots(args, stagingRoot: stagingRoot, stateRoot: stateRoot);
    final output = await agentService.runCli(args);
    return ClientUpdateStatus.fromJson(output);
  }

  void _appendRoots(
    List<String> args, {
    String stagingRoot = '',
    String stateRoot = '',
  }) {
    if (stagingRoot.trim().isNotEmpty) {
      args.addAll(['--staging-root', stagingRoot.trim()]);
    }
    if (stateRoot.trim().isNotEmpty) {
      args.addAll(['--state-root', stateRoot.trim()]);
    }
  }
}
