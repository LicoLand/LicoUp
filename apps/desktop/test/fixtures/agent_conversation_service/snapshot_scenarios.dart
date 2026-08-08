import 'dart:convert';
import 'dart:io';

import 'package:licoup/src/backend/features/agents/services/agent_conversation_service.dart';
import 'package:licoup/src/platform/native_client/agent_service.dart';
import 'package:flutter_test/flutter_test.dart';

void registerAgentConversationArchiveScenarios() {
  test('collects native conversation snapshots by topic and agent', () async {
    final captured = <List<String>>[];
    final agentService = AgentService(
      runCliExecutable: (executable, args, env) async {
        captured.add(List<String>.from(args));
        return ProcessResult(
          0,
          0,
          jsonEncode({
            'ok': true,
            'status': 'materialized',
            'selectedCount': 1,
          }),
          '',
        );
      },
    );
    const service = AgentConversationService();

    final result = await service.collectSnapshots(
      agentService: agentService,
      agentId: 'codex',
      topic: ' codex spark ',
    );

    expect(result['status'], 'materialized');
    expect(captured.single, [
      'snapshots',
      'collect',
      '--topic',
      'codex spark',
      '--agent',
      'codex',
    ]);
  });

  test(
    'previews, binds, creates, and drains native conversation archive jobs',
    () async {
      final captured = <List<String>>[];
      final agentService = AgentService(
        runCliExecutable: (executable, args, env) async {
          captured.add(List<String>.from(args));
          return ProcessResult(
            0,
            0,
            jsonEncode({
              'ok': true,
              'jobId': 'archive-job-1',
              'status': args.contains('drain') ? 'drained' : 'queued',
            }),
            '',
          );
        },
      );
      const service = AgentConversationService();

      final preview = await service.previewArchiveJob(
        agentService: agentService,
        selectionMode: 'exact-keyword',
        query: ' Pactium ',
        sourceAgentId: 'codex',
        path: ' test-data/pactium ',
      );
      final created = await service.createArchiveJob(
        agentService: agentService,
        selectionMode: 'exact-keyword',
        query: ' Pactium ',
        sourceAgentId: 'codex',
        path: ' test-data/pactium ',
        planBinding: 'sha256:fixture-plan',
      );
      await service.archiveJobStatus(
        agentService: agentService,
        jobId: 'archive-job-1',
      );
      await service.archiveJobEvents(
        agentService: agentService,
        jobId: 'archive-job-1',
      );
      await service.drainArchiveJobs(
        agentService: agentService,
        jobId: 'archive-job-1',
      );

      expect(preview['jobId'], 'archive-job-1');
      expect(created['jobId'], 'archive-job-1');
      expect(captured[0], [
        'snapshots',
        'archive',
        'jobs',
        'preview',
        '--selection-mode',
        'exact-keyword',
        '--query',
        'Pactium',
        '--agent',
        'codex',
        '--path',
        'test-data/pactium',
      ]);
      expect(captured[1], [
        'snapshots',
        'archive',
        'jobs',
        'create',
        '--selection-mode',
        'exact-keyword',
        '--query',
        'Pactium',
        '--agent',
        'codex',
        '--path',
        'test-data/pactium',
        '--plan-binding',
        'sha256:fixture-plan',
        '--max-attempts',
        '2',
      ]);
      expect(captured[2], [
        'snapshots',
        'archive',
        'jobs',
        'status',
        '--job-id',
        'archive-job-1',
      ]);
      expect(captured[3], [
        'snapshots',
        'archive',
        'jobs',
        'events',
        '--job-id',
        'archive-job-1',
      ]);
      expect(captured[4], [
        'snapshots',
        'archive',
        'jobs',
        'drain',
        '--job-id',
        'archive-job-1',
      ]);
    },
  );

  test('manages snapshot root collections and bridge commands', () async {
    final captured = <List<String>>[];
    final agentService = AgentService(
      runCliExecutable: (executable, args, env) async {
        captured.add(List<String>.from(args));
        if (args.length >= 3 && args[1] == 'collections') {
          return ProcessResult(
            0,
            0,
            jsonEncode({
              'ok': true,
              'collections': [
                {'topicKey': 'codex-spark'},
              ],
            }),
            '',
          );
        }
        if (args.length >= 3 && args[1] == 'profiles') {
          return ProcessResult(
            0,
            0,
            jsonEncode({
              'ok': true,
              'profiles': [
                {'profileId': 'licomesh'},
              ],
            }),
            '',
          );
        }
        return ProcessResult(
          0,
          0,
          jsonEncode({'ok': true, 'snapshotRoot': 'test-data/archive'}),
          '',
        );
      },
    );
    const service = AgentConversationService();

    await service.getSnapshotRoot(agentService: agentService);
    await service.setSnapshotRoot(
      agentService: agentService,
      path: 'test-data/archive',
    );
    final collections = await service.listSnapshotCollections(
      agentService: agentService,
    );
    final profiles = await service.listArchiveProfiles(
      agentService: agentService,
    );
    await service.runArchiveProfile(
      agentService: agentService,
      profileId: 'licomesh',
      trigger: 'agent',
    );
    await service.verifyArchiveProfile(
      agentService: agentService,
      profileId: 'licomesh',
    );
    await service.reportArchiveProfile(
      agentService: agentService,
      profileId: 'licomesh',
    );

    expect(collections.single['topicKey'], 'codex-spark');
    expect(profiles.single['profileId'], 'licomesh');
    expect(captured[0], ['snapshots', 'root', 'get']);
    expect(captured[1], [
      'snapshots',
      'root',
      'set',
      '--path',
      'test-data/archive',
    ]);
    expect(captured[2], ['snapshots', 'collections', 'list']);
    expect(captured[3], ['snapshots', 'profiles', 'list']);
    expect(captured[4], [
      'snapshots',
      'archive',
      'run',
      '--profile',
      'licomesh',
      '--trigger',
      'agent',
    ]);
    expect(captured[5], [
      'snapshots',
      'archive',
      'verify',
      '--profile',
      'licomesh',
    ]);
    expect(captured[6], [
      'snapshots',
      'archive',
      'report',
      '--profile',
      'licomesh',
    ]);
  });
}

void main() => registerAgentConversationArchiveScenarios();
