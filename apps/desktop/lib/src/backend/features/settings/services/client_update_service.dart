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
  }) async {
    final output = await agentService.runCli([
      'update',
      'status',
      '--channel',
      channel.trim().isEmpty ? 'stable' : channel.trim(),
    ]);
    return ClientUpdateStatus.fromJson(output);
  }

  @override
  Future<ClientUpdateStatus> check({
    required AgentCommandRunner agentService,
    required String manifestPath,
    required String publicKeysPath,
    String channel = 'stable',
    String revocationPath = '',
  }) async {
    final args = [
      'update',
      'check',
      '--channel',
      channel.trim().isEmpty ? 'stable' : channel.trim(),
      '--manifest-path',
      manifestPath.trim(),
      '--public-keys-path',
      publicKeysPath.trim(),
    ];
    if (revocationPath.trim().isNotEmpty) {
      args.addAll(['--revocation-path', revocationPath.trim()]);
    }
    final output = await agentService.runCli(args);
    return ClientUpdateStatus.fromJson(output);
  }

  @override
  Future<ClientUpdateStatus> download({
    required AgentCommandRunner agentService,
    required String manifestPath,
    required String publicKeysPath,
    required String sourcePath,
    String channel = 'stable',
    String revocationPath = '',
    String stagingRoot = '',
  }) async {
    final args = [
      'update',
      'download',
      '--channel',
      channel.trim().isEmpty ? 'stable' : channel.trim(),
      '--manifest-path',
      manifestPath.trim(),
      '--public-keys-path',
      publicKeysPath.trim(),
      '--source-path',
      sourcePath.trim(),
    ];
    if (revocationPath.trim().isNotEmpty) {
      args.addAll(['--revocation-path', revocationPath.trim()]);
    }
    if (stagingRoot.trim().isNotEmpty) {
      args.addAll(['--staging-root', stagingRoot.trim()]);
    }
    final output = await agentService.runCli(args);
    return ClientUpdateStatus.fromJson(output);
  }

  @override
  Future<ClientUpdateStatus> verify({
    required AgentCommandRunner agentService,
    required String manifestPath,
    required String publicKeysPath,
    String channel = 'stable',
    String revocationPath = '',
    String stagingRoot = '',
  }) async {
    final args = [
      'update',
      'verify',
      '--channel',
      channel.trim().isEmpty ? 'stable' : channel.trim(),
      '--manifest-path',
      manifestPath.trim(),
      '--public-keys-path',
      publicKeysPath.trim(),
    ];
    if (revocationPath.trim().isNotEmpty) {
      args.addAll(['--revocation-path', revocationPath.trim()]);
    }
    if (stagingRoot.trim().isNotEmpty) {
      args.addAll(['--staging-root', stagingRoot.trim()]);
    }
    final output = await agentService.runCli(args);
    return ClientUpdateStatus.fromJson(output);
  }

  @override
  Future<ClientUpdateStatus> applyDryRun({
    required AgentCommandRunner agentService,
    required String manifestPath,
    required String publicKeysPath,
    String channel = 'stable',
    String revocationPath = '',
    String stagingRoot = '',
  }) async {
    final args = [
      'update',
      'apply',
      '--channel',
      channel.trim().isEmpty ? 'stable' : channel.trim(),
      '--manifest-path',
      manifestPath.trim(),
      '--public-keys-path',
      publicKeysPath.trim(),
      '--execute',
      'false',
    ];
    if (revocationPath.trim().isNotEmpty) {
      args.addAll(['--revocation-path', revocationPath.trim()]);
    }
    if (stagingRoot.trim().isNotEmpty) {
      args.addAll(['--staging-root', stagingRoot.trim()]);
    }
    final output = await agentService.runCli(args);
    return ClientUpdateStatus.fromJson(output);
  }
}
