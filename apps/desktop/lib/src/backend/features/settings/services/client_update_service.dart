import 'package:flutter_client/src/contracts/agent_command_runner.dart';
import 'package:flutter_client/src/contracts/client_update_models.dart';

export 'package:flutter_client/src/contracts/client_update_models.dart';

class ClientUpdateService {
  const ClientUpdateService();

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

  Future<ClientUpdateStatus> download({
    required AgentCommandRunner agentService,
    required String sourcePath,
    String stagingRoot = '',
    int size = 0,
  }) async {
    final args = ['update', 'download', '--source-path', sourcePath.trim()];
    if (stagingRoot.trim().isNotEmpty) {
      args.addAll(['--staging-root', stagingRoot.trim()]);
    }
    if (size > 0) {
      args.addAll(['--size', size.toString()]);
    }
    final output = await agentService.runCli(args);
    return ClientUpdateStatus.fromJson(output);
  }

  Future<ClientUpdateStatus> verify({
    required AgentCommandRunner agentService,
    required String manifestPath,
    required String publicKeysPath,
    required String stagedFileName,
    String sha256 = '',
    String stagingRoot = '',
  }) async {
    final args = [
      'update',
      'verify',
      '--manifest-path',
      manifestPath.trim(),
      '--public-keys-path',
      publicKeysPath.trim(),
      '--staged-file-name',
      stagedFileName.trim(),
    ];
    if (sha256.trim().isNotEmpty) {
      args.addAll(['--sha256', sha256.trim()]);
    }
    if (stagingRoot.trim().isNotEmpty) {
      args.addAll(['--staging-root', stagingRoot.trim()]);
    }
    final output = await agentService.runCli(args);
    return ClientUpdateStatus.fromJson(output);
  }

  Future<ClientUpdateStatus> applyDryRun({
    required AgentCommandRunner agentService,
    required String manifestPath,
    required String publicKeysPath,
    required String stagedFileName,
    String sha256 = '',
    String stagingRoot = '',
  }) async {
    final args = [
      'update',
      'apply',
      '--manifest-path',
      manifestPath.trim(),
      '--public-keys-path',
      publicKeysPath.trim(),
      '--staged-file-name',
      stagedFileName.trim(),
      '--execute',
      'false',
    ];
    if (sha256.trim().isNotEmpty) {
      args.addAll(['--sha256', sha256.trim()]);
    }
    if (stagingRoot.trim().isNotEmpty) {
      args.addAll(['--staging-root', stagingRoot.trim()]);
    }
    final output = await agentService.runCli(args);
    return ClientUpdateStatus.fromJson(output);
  }
}
