import 'package:path/path.dart' as p;

import 'package:flutter_client/src/application/features/agents/archive/conversation_archive_job_controller.dart';

import '../support/client_controller_scenario_dependencies.dart';
import '../support/client_controller_scenario_json.dart';
import '../support/fake_agent_service.dart';

void registerClientConversationArchiveScenarios() {
  test(
    'exact-keyword archive previews a bound plan and observes completion',
    () async {
      final service = FakeAgentService()
        ..archiveJobDrainGate = Completer<void>();
      final controller = ClientController(agentService: service);
      addTearDown(controller.dispose);

      await controller.archiveConversationExactKeyword(
        query: '  Pactium  ',
        path: ' /tmp/pactium ',
      );

      expect(service.scanTargetsCalls, 0);
      expect(
        service.archiveJobPreviewCalls,
        1,
        reason:
            'destination=${controller.archiveDestinationDraft} '
            'query=${controller.archiveQueryDraft} '
            'collecting=${controller.isCollectingConversationArchive} '
            'error=${controller.lastError}',
      );
      expect(service.archiveJobCreateCalls, 1);
      expect(service.archiveJobDrainCalls, 1);
      expect(
        service.cliCalls.any(
          (args) =>
              args.length >= 3 &&
              args[0] == 'snapshots' &&
              args[1] == 'archive' &&
              args[2] == 'collect',
        ),
        isFalse,
      );
      expect(service.archiveSelectionMode, 'exact-keyword');
      expect(service.archiveQuery, 'Pactium');
      expect(service.archivePlanBinding, 'sha256:fake-archive-plan');
      expect(service.archiveDestinationPath, '/tmp/pactium');
      expect(controller.conversationArchivePlan?['count'], 2);
      expect(controller.isCollectingConversationArchive, isTrue);
      expect(controller.selectedConversationArchiveJobId, 'archive-job-1');
      expect(controller.conversationArchiveResult?['status'], 'queued');
      expect(
        controller.conversationArchiveResult?['targetScan']?['clientCount'],
        1,
      );
      expect(controller.statusMessage, contains('归档计划已绑定 2 条本机对话'));

      service.archiveJobDrainGate!.complete();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(service.archiveJobStatusCalls, 1);
      expect(service.archiveJobEventsCalls, 1);
      expect(controller.conversationArchiveResult?['status'], 'completed');
      expect(
        controller.conversationArchiveResult?['workflow']?['status'],
        'completed',
      );
      expect(controller.conversationSnapshotCollections, hasLength(1));
      expect(controller.isCollectingConversationArchive, isFalse);
      expect(controller.statusMessage, '已归档 2 条原生对话到目录，本机校验 ok。');
      expect(controller.statusCaption, 'Conversation archive');
    },
  );

  test(
    'archiveSelectedConversationAgent writes into agent subdirectory',
    () async {
      final service = FakeAgentService()
        ..archiveJobDrainGate = Completer<void>();
      final controller = ClientController(agentService: service);
      addTearDown(controller.dispose);

      controller.scannedTargets = [agentArchiveTarget()];
      controller.selectedConversationAgentId = 'claude-code';
      controller.archiveDestinationController.text = '/tmp/native-archive';

      await controller.archiveSelectedConversationAgent();

      expect(service.archiveJobPreviewCalls, 1);
      expect(service.archiveJobCreateCalls, 1);
      expect(service.archiveJobDrainCalls, 1);
      expect(service.archiveSelectionMode, 'all');
      expect(service.archiveQuery, isEmpty);
      expect(service.archiveSourceAgentId, 'claude-code');
      expect(
        service.archiveDestinationPath,
        p.join('/tmp/native-archive', 'claude-code'),
      );
      expect(controller.isCollectingConversationArchive, isTrue);

      service.archiveJobDrainGate!.complete();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
    },
  );

  test(
    'archive destination scope is explicit for global and agent backups',
    () {
      final controller = ClientController(agentService: FakeAgentService());
      addTearDown(controller.dispose);
      controller.archiveDestinationDraft = '/tmp/native-archive';

      expect(
        controller.conversationArchiveDestinationFor(
          selectionMode: conversationArchiveAllSelection,
        ),
        '/tmp/native-archive',
      );
      expect(
        controller.conversationArchiveDestinationFor(
          selectionMode: conversationArchiveAllSelection,
          sourceAgentId: 'claude-code',
        ),
        p.join('/tmp/native-archive', 'claude-code'),
      );
      expect(
        controller.conversationArchiveDestinationFor(
          selectionMode: conversationArchiveExactKeywordSelection,
          sourceAgentId: 'claude-code',
        ),
        '/tmp/native-archive',
      );
    },
  );

  test(
    'archiveSelectedConversationAgent requires settings archive path',
    () async {
      final service = FakeAgentService();
      final controller = ClientController(agentService: service);
      addTearDown(controller.dispose);

      controller.scannedTargets = [agentArchiveTarget()];
      controller.selectedConversationAgentId = 'claude-code';

      await controller.archiveSelectedConversationAgent();

      expect(service.archiveJobPreviewCalls, 0);
      expect(service.archiveJobCreateCalls, 0);
      expect(controller.statusMessage, '请先在设置中指定对话归档目录。');
      expect(controller.statusCaption, 'Agent archive');
    },
  );

  test('archive retry events are surfaced from native job events', () async {
    final service = FakeAgentService()..archiveJobAttempt = 2;
    final controller = ClientController(agentService: service);
    addTearDown(controller.dispose);

    await controller.archiveConversationExactKeyword(
      query: 'Pactium',
      path: '/tmp/pactium',
    );
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(service.archiveVerifyCalls, 0);
    expect(service.archiveJobDrainCalls, 1);
    expect(
      controller.conversationArchiveResult?['workflow']?['status'],
      'completed',
    );
    expect(controller.conversationArchiveResult?['workflow']?['attempt'], 2);
    expect(
      controller.conversationArchiveWorkflowEvents.any(
        (event) =>
            event['type'] == 'archive.retry.scheduled' &&
            event['status'] == 'retry_scheduled',
      ),
      isTrue,
    );
    expect(
      controller.conversationArchiveResult?['validation']?['healthStatus'],
      'ok',
    );
  });

  test('snapshot root settings call snapshot CLI surface', () async {
    final service = FakeAgentService();
    final controller = ClientController(agentService: service);
    addTearDown(controller.dispose);

    await controller.refreshConversationSnapshotRoot();
    expect(controller.snapshotRootController.text, service.snapshotRootPath);

    await controller.setConversationSnapshotRoot('/tmp/native-archive');
    expect(service.snapshotRootSetCalls, 1);
    expect(controller.snapshotRootController.text, '/tmp/native-archive');
  });

  test('archive profile actions update controller health state', () async {
    final service = FakeAgentService();
    final controller = ClientController(agentService: service);
    addTearDown(controller.dispose);

    await controller.refreshConversationArchiveProfiles();
    expect(service.archiveProfilesListCalls, 1);
    expect(controller.conversationArchiveProfiles, hasLength(1));
    expect(controller.selectedArchiveProfileId, 'licolite');

    await controller.runSelectedConversationArchiveProfile();
    expect(service.archiveRunCalls, 1);
    expect(service.archiveProfileId, 'licolite');
    expect(
      controller.conversationArchiveResult?['mode'],
      'conversation-archive',
    );
    expect(
      controller.conversationArchiveReport?['validation']['healthStatus'],
      'ok',
    );
    expect(controller.statusMessage, '项目归档完成：2 条，健康状态 ok。');

    await controller.verifySelectedConversationArchiveProfile();
    expect(service.archiveVerifyCalls, 1);
    expect(
      controller.conversationArchiveReport?['mode'],
      'conversation-archive-verify',
    );

    await controller.reportSelectedConversationArchiveProfile();
    expect(service.archiveReportCalls, 1);
    expect(
      controller.conversationArchiveReport?['mode'],
      'conversation-archive-report',
    );
  });
}
