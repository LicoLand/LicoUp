import 'dart:convert';
import 'dart:io';

import 'package:flutter_client/src/services/agent_conversation_service.dart';
import 'package:flutter_client/src/services/agent_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'loads native agent histories through lico-client conversations list',
    () async {
      final captured = <List<String>>[];
      final agentService = AgentService(
        runCliExecutable: (executable, args, env) async {
          captured.add(List<String>.from(args));
          if (args[1] == 'list') {
            return ProcessResult(
              0,
              0,
              jsonEncode({
                'ok': true,
                'sessions': [
                  _sessionJson('session-1', 'Summarize this local repo.'),
                ],
              }),
              '',
            );
          }
          return ProcessResult(0, 0, jsonEncode({'ok': true}), '');
        },
      );
      const service = AgentConversationService();

      final sessions = await service.loadSessions(
        agentService: agentService,
        agentId: 'codex',
      );

      expect(sessions, hasLength(1));
      expect(sessions.single.agentId, 'codex');
      expect(sessions.single.native, isTrue);
      expect(sessions.single.readOnly, isTrue);
      expect(sessions.single.adapterId, 'codex');
      expect(sessions.single.nativeSessionId, 'codex-session-1');
      expect(sessions.single.sourceKind, 'codex-session-store');
      expect(sessions.single.importMode, 'precise-adapter');
      expect(sessions.single.sourceTool, 'codex');
      expect(sessions.single.sourcePath, '/tmp/codex/history.jsonl');
      expect(sessions.single.messageCount, 2);
      expect(captured.single, ['conversations', 'list', '--agent', 'codex']);
    },
  );

  test('sends messages through lico-client runtime adapter command', () async {
    final captured = <List<String>>[];
    final agentService = AgentService(
      runCliExecutable: (executable, args, env) async {
        captured.add(List<String>.from(args));
        return ProcessResult(
          0,
          0,
          jsonEncode({
            'ok': true,
            'mode': 'runtime-adapter',
            'adapterId': 'codex',
            'runtimeProtocol': 'codex-cli-exec',
          }),
          '',
        );
      },
    );
    const service = AgentConversationService();

    final result = await service.sendRuntimeMessage(
      agentService: agentService,
      agentId: 'codex',
      text: 'Hello Codex',
      sessionId: 'native-session-1',
    );

    expect(result['ok'], isTrue);
    expect(result['mode'], 'runtime-adapter');
    expect(captured.single, [
      'agent',
      'message',
      'send',
      '--agent',
      'codex',
      '--text',
      'Hello Codex',
      '--session-id',
      'native-session-1',
    ]);
  });

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
      '--curation',
      'true',
      '--agent',
      'codex',
    ]);
  });

  test('creates and drains native conversation archive jobs', () async {
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

    final created = await service.createArchiveJob(
      agentService: agentService,
      keywords: ' Pact, Pactium ',
      path: ' /tmp/pactium ',
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

    expect(created['jobId'], 'archive-job-1');
    expect(captured[0], [
      'snapshots',
      'archive',
      'jobs',
      'create',
      '--keywords',
      'Pact, Pactium',
      '--path',
      '/tmp/pactium',
      '--curation',
      'true',
      '--max-attempts',
      '2',
    ]);
    expect(captured[1], [
      'snapshots',
      'archive',
      'jobs',
      'status',
      '--job-id',
      'archive-job-1',
    ]);
    expect(captured[2], [
      'snapshots',
      'archive',
      'jobs',
      'events',
      '--job-id',
      'archive-job-1',
    ]);
    expect(captured[3], [
      'snapshots',
      'archive',
      'jobs',
      'drain',
      '--job-id',
      'archive-job-1',
    ]);
  });

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
                {'profileId': 'licolite'},
              ],
            }),
            '',
          );
        }
        return ProcessResult(
          0,
          0,
          jsonEncode({'ok': true, 'snapshotRoot': '/tmp/archive'}),
          '',
        );
      },
    );
    const service = AgentConversationService();

    await service.getSnapshotRoot(agentService: agentService);
    await service.setSnapshotRoot(
      agentService: agentService,
      path: '/tmp/archive',
    );
    final collections = await service.listSnapshotCollections(
      agentService: agentService,
    );
    await service.ensureSnapshotBridge(
      agentService: agentService,
      agentId: 'codex',
      configPath: '/tmp/codex.toml',
    );
    await service.getPreferredSnapshotCurator(agentService: agentService);
    await service.setPreferredSnapshotCurator(
      agentService: agentService,
      target: 'codex',
    );
    await service.setPreferredSnapshotCurator(
      agentService: agentService,
      target: '',
    );
    final profiles = await service.listArchiveProfiles(
      agentService: agentService,
    );
    await service.runArchiveProfile(
      agentService: agentService,
      profileId: 'licolite',
      trigger: 'agent',
    );
    await service.verifyArchiveProfile(
      agentService: agentService,
      profileId: 'licolite',
    );
    await service.reportArchiveProfile(
      agentService: agentService,
      profileId: 'licolite',
    );

    expect(collections.single['topicKey'], 'codex-spark');
    expect(profiles.single['profileId'], 'licolite');
    expect(captured[0], ['snapshots', 'root', 'get']);
    expect(captured[1], ['snapshots', 'root', 'set', '--path', '/tmp/archive']);
    expect(captured[2], ['snapshots', 'collections', 'list']);
    expect(captured[3], [
      'snapshots',
      'bridge',
      'ensure',
      '--target',
      'codex',
      '--config-path',
      '/tmp/codex.toml',
    ]);
    expect(captured[4], ['snapshots', 'curator', 'get']);
    expect(captured[5], ['snapshots', 'curator', 'set', '--target', 'codex']);
    expect(captured[6], ['snapshots', 'curator', 'set', '--clear', 'true']);
    expect(captured[7], ['snapshots', 'profiles', 'list']);
    expect(captured[8], [
      'snapshots',
      'archive',
      'run',
      '--profile',
      'licolite',
      '--trigger',
      'agent',
      '--curation',
      'true',
    ]);
    expect(captured[9], [
      'snapshots',
      'archive',
      'verify',
      '--profile',
      'licolite',
    ]);
    expect(captured[10], [
      'snapshots',
      'archive',
      'report',
      '--profile',
      'licolite',
    ]);
  });
}

Map<String, dynamic> _sessionJson(String id, String text) {
  return {
    'id': id,
    'agentId': 'codex',
    'title': text,
    'createdAt': '2026-06-12T00:00:00Z',
    'updatedAt': '2026-06-12T00:00:01Z',
    'adapterId': 'codex',
    'nativeSessionId': 'codex-session-1',
    'sourceKind': 'codex-session-store',
    'importMode': 'precise-adapter',
    'sourceTool': 'codex',
    'sourcePath': '/tmp/codex/history.jsonl',
    'native': true,
    'readOnly': true,
    'messageCount': 2,
    'messages': [
      {
        'id': 'msg-1',
        'role': 'user',
        'text': text,
        'createdAt': '2026-06-12T00:00:00Z',
      },
      {
        'id': 'msg-2',
        'role': 'agent',
        'text': '本机展示',
        'createdAt': '2026-06-12T00:00:01Z',
      },
    ],
  };
}
