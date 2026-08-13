import 'package:licoup/src/application/features/navigation/controller/client_current_view_tracker.dart';
import 'package:licoup/src/contracts/presentation/client_current_view.dart';

import 'fixtures/client_controller/support/client_controller_scenario_dependencies.dart';
import 'fixtures/client_controller/support/client_controller_scenario_json.dart';
import 'fixtures/client_controller/support/fake_agent_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  late PortableDataRoot portableData;
  late ClientCurrentViewTracker tracker;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('lico-current-view-');
    portableData = PortableDataRoot(dataDirectoryOverride: directory);
    tracker = ClientCurrentViewTracker();
  });

  tearDown(() async {
    await tracker.flush();
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  });

  TargetCandidate codexTarget() => TargetCandidate(
    target: 'codex',
    label: 'Codex',
    kind: 'cli',
    status: 'detected',
    configured: false,
    confidence: 0.82,
    adapterStatus: 'implemented',
  );

  TargetCandidate claudeCodeTarget() => TargetCandidate(
    target: 'claude-code',
    label: 'Claude Code',
    kind: 'cli',
    status: 'detected',
    configured: false,
    confidence: 0.9,
    adapterStatus: 'implemented',
  );

  ClientController newController({FakeAgentService? agentService}) =>
      ClientController(
        portableData: portableData,
        agentService: agentService ?? _CurrentViewAgentService(),
        currentViewTracker: tracker,
      );

  ClientController relaunchController({FakeAgentService? agentService}) {
    tracker = ClientCurrentViewTracker();
    return newController(agentService: agentService);
  }

  Future<void> removeScannedTargetCache() async {
    final dataDir = await portableData.clientDirectory();
    final cache = File('${dataDir.path}/scanned-targets-cache.json');
    if (await cache.exists()) await cache.delete();
  }

  test('reopens the exact Agent conversation after relaunch', () async {
    final first = newController();
    addTearDown(first.dispose);
    await first.initialize();
    first.scannedTargets = [codexTarget()];
    first.selectedConversationAgentId = 'codex';

    final saved = await first.conversationCommitTurnBoundNativeReadback(
      agentId: 'codex',
      nativeSessionId: 'native-synthetic-session',
      mergeWithSelectedSession: false,
      messages: const [
        AgentConversationMessage(
          id: 'synthetic-user',
          role: 'user',
          text: 'Continue the last conversation',
          createdAt: '2026-08-07T00:00:00.000Z',
        ),
        AgentConversationMessage(
          id: 'synthetic-assistant',
          role: 'assistant',
          text: 'Synthetic persisted response',
          createdAt: '2026-08-07T00:00:01.000Z',
        ),
      ],
    );
    expect(saved, isTrue);
    final sessionId = first.selectedConversationSessionId;
    expect(sessionId, isNotEmpty);
    await tracker.flush();

    final secondService = _CurrentViewAgentService()
      ..scanTargetsResult = [codexTarget()]
      ..conversationSessions['codex'] = [
        conversationSessionJson(
          id: 'native-synthetic-session',
          agentId: 'codex',
          text: 'Continue the last conversation',
        ),
      ];
    final second = relaunchController(agentService: secondService);
    addTearDown(second.dispose);
    await second.initialize();

    expect(second.currentSection, ClientSection.agents);
    expect(second.selectedConversationAgentId, 'codex');
    expect(second.selectedConversationSessionId, sessionId);
  });

  test('reopens Local instead of the previously used Agent', () async {
    final firstService = _CurrentViewAgentService()
      ..scanTargetsResult = [codexTarget()];
    final first = newController(agentService: firstService);
    addTearDown(first.dispose);
    await first.initialize();

    first.scannedTargets = [codexTarget()];
    first.selectedConversationAgentId = 'codex';
    first.agentWorkspaceRecordCurrentAgentView();
    await first.clientConversationController.selectConversation(
      _CurrentViewAgentService.groupId,
    );
    await tracker.flush();

    final second = relaunchController(
      agentService: _CurrentViewAgentService()
        ..scanTargetsResult = [codexTarget()],
    );
    addTearDown(second.dispose);
    await second.initialize();

    expect(second.selectedConversationAgentId, isEmpty);
    expect(
      second.clientConversationController.selectedConversationId,
      _CurrentViewAgentService.groupId,
    );
    expect(
      second.clientConversationController.selectedConversation?.title,
      'Local',
    );
  });

  test('restores the top-level section without forgetting Local', () async {
    final first = newController();
    addTearDown(first.dispose);
    await first.initialize();
    await first.clientConversationController.selectConversation(
      _CurrentViewAgentService.groupId,
    );
    first.selectSection(ClientSection.settings);
    await tracker.flush();

    final second = relaunchController();
    addTearDown(second.dispose);
    await second.initialize();
    await second.applyCurrentConversationViewRestore();

    expect(second.currentSection, ClientSection.settings);
    expect(
      second.clientConversationController.selectedConversationId,
      _CurrentViewAgentService.groupId,
    );

    second.selectSection(ClientSection.agents);
    expect(
      tracker.current,
      ClientCurrentView.group(
        section: ClientSection.agents,
        conversationId: _CurrentViewAgentService.groupId,
      ),
    );
  });

  test('the final view wins after rapid cross-interface switches', () async {
    final first = newController();
    addTearDown(first.dispose);
    await first.initialize();

    first.selectSection(ClientSection.models);
    first.selectSection(ClientSection.settings);
    first.selectSection(ClientSection.agents);
    first.showConversationWelcomePage();
    await first.clientConversationController.selectConversation(
      _CurrentViewAgentService.groupId,
    );
    await tracker.flush();

    final second = relaunchController();
    addTearDown(second.dispose);
    await second.initialize();

    expect(second.currentSection, ClientSection.agents);
    expect(
      second.clientConversationController.selectedConversationId,
      _CurrentViewAgentService.groupId,
    );
  });

  test('fresh desktop launch stays on Welcome', () async {
    final controller = newController(
      agentService: _CurrentViewAgentService()
        ..scanTargetsResult = [codexTarget()],
    );
    addTearDown(controller.dispose);

    await controller.initialize();

    expect(controller.currentSection, ClientSection.agents);
    expect(controller.selectedConversationAgentId, isEmpty);
    expect(controller.selectedConversationSessionId, isEmpty);
    expect(
      controller.clientConversationController.selectedConversationId,
      isEmpty,
    );
  });

  test('missing restored Agent does not select an unrelated Agent', () async {
    final first = newController();
    addTearDown(first.dispose);
    await first.initialize();
    first.scannedTargets = [codexTarget()];
    first.selectedConversationAgentId = 'codex';
    first.agentWorkspaceRecordCurrentAgentView();
    await tracker.flush();
    await removeScannedTargetCache();

    final second = relaunchController(
      agentService: _CurrentViewAgentService()
        ..scanTargetsResult = [claudeCodeTarget()],
    );
    addTearDown(second.dispose);
    await second.initialize();

    expect(second.selectedConversationAgentId, isEmpty);
    expect(second.selectedConversationSessionId, isEmpty);
  });

  test(
    'restore still applies when targets settle before tracker load',
    () async {
      final first = newController();
      addTearDown(first.dispose);
      await first.initialize();
      first.scannedTargets = [codexTarget()];
      first.selectedConversationAgentId = 'codex';
      first.agentWorkspaceRecordCurrentAgentView();
      await tracker.flush();

      final second = relaunchController();
      addTearDown(second.dispose);
      second.scannedTargets = [claudeCodeTarget(), codexTarget()];
      second.selectDefaultConversationAgent();
      expect(second.selectedConversationAgentId, isEmpty);

      await second.initialize();
      expect(second.selectedConversationAgentId, 'codex');
    },
  );
}

final class _CurrentViewAgentService extends FakeAgentService {
  static const groupId = 'conversation:local';

  @override
  Future<Map<String, dynamic>> runCliWithStdin(
    List<String> args,
    String stdinText,
  ) async {
    if (args.isNotEmpty && args.first == 'conversation') {
      final request = Map<String, dynamic>.from(jsonDecode(stdinText) as Map);
      return {
        'ok': true,
        'result': switch (request['action']) {
          'conversation.list' => [_groupSummary],
          'conversation.get' => _groupConversation,
          'conversation.events.page' => const {
            'events': <Map<String, dynamic>>[],
            'nextCursor': null,
            'totalCount': 0,
          },
          _ => const <String, dynamic>{},
        },
      };
    }
    return super.runCliWithStdin(args, stdinText);
  }
}

const _groupSummary = <String, dynamic>{
  'id': _CurrentViewAgentService.groupId,
  'title': 'Local',
  'archived': false,
  'pinned': true,
  'isGroup': true,
  'revision': 1,
  'updatedAtUnixMs': 10,
  'membershipCount': 2,
  'eventCount': 0,
};

const _groupConversation = <String, dynamic>{
  'id': _CurrentViewAgentService.groupId,
  'title': 'Local',
  'archived': false,
  'pinned': true,
  'isGroup': true,
  'revision': 1,
  'createdAtUnixMs': 1,
  'updatedAtUnixMs': 10,
  'eventCount': 0,
  'memberships': [
    {
      'id': 'membership:owner',
      'conversationId': _CurrentViewAgentService.groupId,
      'principal': {
        'id': 'human:local',
        'kind': 'human',
        'displayName': 'Local User',
        'createdAtUnixMs': 1,
      },
      'access': 'owner',
      'status': 'active',
      'joinedAtUnixMs': 1,
    },
    {
      'id': 'membership:codex',
      'conversationId': _CurrentViewAgentService.groupId,
      'principal': {
        'id': 'agent:codex',
        'kind': 'agent',
        'displayName': 'Codex',
        'agentId': 'codex',
        'createdAtUnixMs': 1,
      },
      'access': 'member',
      'status': 'active',
      'joinedAtUnixMs': 1,
    },
  ],
};
