part of 'package:flutter_client/src/backend/features/agents/services/agent_conversation_service.dart';

extension AgentConversationArchiveService on AgentConversationService {
  Future<Map<String, dynamic>> createArchiveJob({
    required AgentCommandRunner agentService,
    required String keywords,
    required String path,
    bool curation = true,
    int? archiveParallelism,
    int maxAttempts = 2,
  }) {
    final args = [
      'snapshots',
      'archive',
      'jobs',
      'create',
      '--keywords',
      keywords.trim(),
      '--path',
      path.trim(),
      '--curation',
      curation ? 'true' : 'false',
      '--max-attempts',
      maxAttempts.toString(),
    ];
    if (archiveParallelism != null && archiveParallelism > 0) {
      args.addAll(['--archive-parallelism', archiveParallelism.toString()]);
    }
    return agentService.runCli(args);
  }

  Future<Map<String, dynamic>> archiveJobStatus({
    required AgentCommandRunner agentService,
    required String jobId,
  }) {
    return agentService.runCli([
      'snapshots',
      'archive',
      'jobs',
      'status',
      '--job-id',
      jobId.trim(),
    ]);
  }

  Future<Map<String, dynamic>> archiveJobEvents({
    required AgentCommandRunner agentService,
    required String jobId,
  }) {
    return agentService.runCli([
      'snapshots',
      'archive',
      'jobs',
      'events',
      '--job-id',
      jobId.trim(),
    ]);
  }

  Future<Map<String, dynamic>> listArchiveJobs({
    required AgentCommandRunner agentService,
  }) {
    return agentService.runCli(['snapshots', 'archive', 'jobs', 'list']);
  }

  Future<Map<String, dynamic>> cancelArchiveJob({
    required AgentCommandRunner agentService,
    required String jobId,
  }) {
    return agentService.runCli([
      'snapshots',
      'archive',
      'jobs',
      'cancel',
      '--job-id',
      jobId.trim(),
    ]);
  }

  Future<Map<String, dynamic>> drainArchiveJobs({
    required AgentCommandRunner agentService,
    String jobId = '',
    bool once = false,
  }) {
    final args = ['snapshots', 'archive', 'jobs', 'drain'];
    if (jobId.trim().isNotEmpty) {
      args.addAll(['--job-id', jobId.trim()]);
    }
    if (once) {
      args.addAll(['--once', 'true']);
    }
    return agentService.runCli(args);
  }

  Future<Map<String, dynamic>> collectSnapshots({
    required AgentCommandRunner agentService,
    required String topic,
    String agentId = '',
    bool curation = true,
  }) {
    final args = [
      'snapshots',
      'collect',
      '--topic',
      topic.trim(),
      '--curation',
      curation ? 'true' : 'false',
    ];
    if (agentId.trim().isNotEmpty) {
      args.addAll(['--agent', agentId.trim()]);
    }
    return agentService.runCli(args);
  }

  Future<List<Map<String, dynamic>>> listSnapshotCollections({
    required AgentCommandRunner agentService,
  }) async {
    final output = await agentService.runCli([
      'snapshots',
      'collections',
      'list',
    ]);
    if (output['ok'] == true && output['collections'] is List) {
      return (output['collections'] as List)
          .whereType<Map<String, dynamic>>()
          .toList();
    }
    return const [];
  }

  Future<List<Map<String, dynamic>>> listArchiveProfiles({
    required AgentCommandRunner agentService,
  }) async {
    final output = await agentService.runCli(['snapshots', 'profiles', 'list']);
    if (output['ok'] == true && output['profiles'] is List) {
      return (output['profiles'] as List)
          .whereType<Map<String, dynamic>>()
          .toList();
    }
    return const [];
  }

  Future<Map<String, dynamic>> runArchiveProfile({
    required AgentCommandRunner agentService,
    required String profileId,
    String trigger = 'manual',
    bool curation = true,
  }) {
    return agentService.runCli([
      'snapshots',
      'archive',
      'run',
      '--profile',
      profileId.trim(),
      '--trigger',
      trigger.trim().isEmpty ? 'manual' : trigger.trim(),
      '--curation',
      curation ? 'true' : 'false',
    ]);
  }

  Future<Map<String, dynamic>> verifyArchiveProfile({
    required AgentCommandRunner agentService,
    required String profileId,
  }) {
    return agentService.runCli([
      'snapshots',
      'archive',
      'verify',
      '--profile',
      profileId.trim(),
    ]);
  }

  Future<Map<String, dynamic>> reportArchiveProfile({
    required AgentCommandRunner agentService,
    required String profileId,
  }) {
    return agentService.runCli([
      'snapshots',
      'archive',
      'report',
      '--profile',
      profileId.trim(),
    ]);
  }

  Future<Map<String, dynamic>> getSnapshotRoot({
    required AgentCommandRunner agentService,
  }) {
    return agentService.runCli(['snapshots', 'root', 'get']);
  }

  Future<Map<String, dynamic>> setSnapshotRoot({
    required AgentCommandRunner agentService,
    required String path,
  }) {
    return agentService.runCli([
      'snapshots',
      'root',
      'set',
      '--path',
      path.trim(),
    ]);
  }

  Future<Map<String, dynamic>> getPreferredSnapshotCurator({
    required AgentCommandRunner agentService,
  }) {
    return agentService.runCli(['snapshots', 'curator', 'get']);
  }

  Future<Map<String, dynamic>> setPreferredSnapshotCurator({
    required AgentCommandRunner agentService,
    required String target,
  }) {
    final trimmed = target.trim();
    if (trimmed.isEmpty) {
      return agentService.runCli([
        'snapshots',
        'curator',
        'set',
        '--clear',
        'true',
      ]);
    }
    return agentService.runCli([
      'snapshots',
      'curator',
      'set',
      '--target',
      trimmed,
    ]);
  }

  Future<Map<String, dynamic>> ensureSnapshotBridge({
    required AgentCommandRunner agentService,
    required String agentId,
    String configPath = '',
  }) {
    final args = ['snapshots', 'bridge', 'ensure', '--target', agentId.trim()];
    if (configPath.trim().isNotEmpty) {
      args.addAll(['--config-path', configPath.trim()]);
    }
    return agentService.runCli(args);
  }
}
