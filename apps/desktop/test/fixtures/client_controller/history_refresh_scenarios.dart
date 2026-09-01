import 'support/client_controller_scenario_dependencies.dart';
import 'support/client_controller_scenario_json.dart';
import 'support/fake_agent_service.dart';

void registerClientHistoryRefreshScenarios() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'loadConversationSessions streams and keeps latest history first',
    () async {
      final service = FakeAgentService()
        ..conversationSessions['codex'] = [
          conversationSessionJson(
            id: 'native-codex-old',
            agentId: 'codex',
            text: 'Older native Codex history',
            updatedAt: '2026-06-12T00:00:01Z',
          ),
          conversationSessionJson(
            id: 'native-codex-new',
            agentId: 'codex',
            text: 'Newer native Codex history',
            updatedAt: '2026-06-13T00:00:01Z',
          ),
        ];
      final controller = ClientController(agentService: service);
      addTearDown(controller.dispose);

      controller.selectedConversationAgentId = 'codex';
      await controller.loadConversationSessions('codex');

      expect(service.conversationStreamCalls, 1);
      expect(service.conversationListCalls, 0);
      expect(
        controller.selectedConversationSessions.map((session) => session.id),
        ['native-codex-new', 'native-codex-old'],
      );
      expect(controller.selectedConversationSession?.id, 'native-codex-new');
    },
  );

  test(
    'loadConversationSessions deduplicates same native session with different ids',
    () async {
      final service = FakeAgentService()
        ..conversationSessions['codex'] = [
          conversationSessionJson(
            id: 'codex-projection-old',
            nativeSessionId: 'codex-native-1',
            agentId: 'codex',
            text: 'Older title',
            updatedAt: '2026-06-12T00:00:01Z',
          ),
          conversationSessionJson(
            id: 'codex-projection-new',
            nativeSessionId: 'codex-native-1',
            agentId: 'codex',
            text: 'Newer title',
            updatedAt: '2026-06-13T00:00:01Z',
          ),
        ];
      final controller = ClientController(agentService: service);
      addTearDown(controller.dispose);

      controller.selectedConversationAgentId = 'codex';
      await controller.loadConversationSessions('codex');

      expect(controller.selectedConversationSessions, hasLength(1));
      expect(
        controller.selectedConversationSessions.single.id,
        'codex-projection-new',
      );
      expect(
        controller.selectedConversationSessions.single.title,
        'Newer title',
      );
    },
  );

  test(
    'provider readback rebinds stale cursor projection ids without losing selection',
    () async {
      final service = FakeAgentService()
        ..conversationSessions['cursor'] = [
          conversationSessionJson(
            id: 'cursor-projection-v1',
            nativeSessionId: 'composer-uuid-1',
            agentId: 'cursor',
            text: 'Cursor first turn',
            updatedAt: '2026-07-10T00:00:01Z',
          ),
        ];
      final controller = ClientController(agentService: service);
      addTearDown(controller.dispose);

      controller.selectedConversationAgentId = 'cursor';
      await controller.loadConversationSessions('cursor');
      controller.selectConversationSession('cursor-projection-v1');

      expect(
        controller.selectedConversationSession?.id,
        'cursor-projection-v1',
      );
      expect(controller.preparingNewConversation, isFalse);

      service.conversationSessions['cursor'] = [
        conversationSessionJson(
          id: 'cursor-projection-v2',
          nativeSessionId: 'composer-uuid-1',
          agentId: 'cursor',
          text: 'Cursor first turn updated',
          updatedAt: '2026-07-10T00:00:02Z',
        ),
      ];

      await controller.refreshConversationSessions('cursor');

      expect(
        controller.selectedConversationSession?.id,
        'cursor-projection-v2',
      );
      expect(
        controller.selectedConversationSession?.messages.first.text,
        'Cursor first turn updated',
      );
      expect(controller.preparingNewConversation, isFalse);
    },
  );

  test(
    'loadConversationSessions grows pages by 10 on every reach to the end',
    () async {
      final pagedSessions = List.generate(220, (index) {
        final updatedAt = DateTime.utc(
          2026,
          6,
          12,
        ).add(Duration(minutes: 120 - index)).toIso8601String();
        return conversationSessionJson(
          id: 'native-codex-${index.toString().padLeft(3, '0')}',
          agentId: 'codex',
          text: 'Paged native Codex history $index',
          updatedAt: updatedAt,
        );
      });
      final service = FakeAgentService()
        ..conversationSessions['codex'] = pagedSessions;
      final controller = ClientController(agentService: service);
      addTearDown(controller.dispose);

      controller.selectedConversationAgentId = 'codex';
      await controller.loadConversationSessions('codex');

      expect(service.conversationStreamCalls, 1);
      expect(service.cliCalls.last, [
        'conversations',
        'stream',
        '--agent',
        'codex',
        '--limit',
        '11',
      ]);
      expect(controller.selectedConversationSessions, hasLength(10));
      expect(
        controller.selectedConversationSessions.first.id,
        'native-codex-000',
      );
      expect(
        controller.selectedConversationSessions.last.id,
        'native-codex-009',
      );
      expect(controller.selectedConversationSessionsHasMore, isTrue);

      await controller.loadMoreConversationSessions('codex');

      expect(service.conversationStreamCalls, 2);
      expect(service.cliCalls.last, [
        'conversations',
        'stream',
        '--agent',
        'codex',
        '--limit',
        '11',
        '--offset',
        '10',
      ]);
      expect(controller.selectedConversationSessions, hasLength(20));
      expect(
        controller.selectedConversationSessions.last.id,
        'native-codex-019',
      );
      expect(controller.selectedConversationSessionsHasMore, isTrue);

      await controller.loadMoreConversationSessions('codex');

      expect(service.conversationStreamCalls, 3);
      expect(service.cliCalls.last, [
        'conversations',
        'stream',
        '--agent',
        'codex',
        '--limit',
        '21',
        '--offset',
        '20',
      ]);
      expect(controller.selectedConversationSessions, hasLength(40));
      expect(
        controller.selectedConversationSessions.last.id,
        'native-codex-039',
      );
      expect(controller.selectedConversationSessionsHasMore, isTrue);

      await controller.loadMoreConversationSessions('codex');

      expect(service.conversationStreamCalls, 4);
      expect(service.cliCalls.last, [
        'conversations',
        'stream',
        '--agent',
        'codex',
        '--limit',
        '31',
        '--offset',
        '40',
      ]);
      expect(controller.selectedConversationSessions, hasLength(70));
      expect(
        controller.selectedConversationSessions.last.id,
        'native-codex-069',
      );
      expect(controller.selectedConversationSessionsHasMore, isTrue);

      await controller.loadMoreConversationSessions('codex');

      expect(service.conversationStreamCalls, 5);
      expect(service.cliCalls.last, [
        'conversations',
        'stream',
        '--agent',
        'codex',
        '--limit',
        '41',
        '--offset',
        '70',
      ]);
      expect(controller.selectedConversationSessions, hasLength(110));
      expect(
        controller.selectedConversationSessions.last.id,
        'native-codex-109',
      );
      expect(controller.selectedConversationSessionsHasMore, isTrue);

      await controller.loadMoreConversationSessions('codex');

      expect(service.conversationStreamCalls, 6);
      expect(service.cliCalls.last, [
        'conversations',
        'stream',
        '--agent',
        'codex',
        '--limit',
        '51',
        '--offset',
        '110',
      ]);
      expect(controller.selectedConversationSessions, hasLength(160));
      expect(controller.selectedConversationSessionsHasMore, isTrue);

      await controller.loadMoreConversationSessions('codex');

      expect(service.conversationStreamCalls, 7);
      expect(service.cliCalls.last, [
        'conversations',
        'stream',
        '--agent',
        'codex',
        '--limit',
        '61',
        '--offset',
        '160',
      ]);
      expect(controller.selectedConversationSessions, hasLength(220));
      expect(controller.selectedConversationSessionsHasMore, isFalse);
    },
  );

  test('streamed catalog publishes cumulative 3 and 10 milestones', () async {
    final service = FakeAgentService()
      ..conversationSessions['codex'] = List.generate(
        50,
        (index) => conversationSessionJson(
          id: 'native-codex-$index',
          agentId: 'codex',
          text: 'Native Codex history $index',
          updatedAt: DateTime.utc(
            2026,
            7,
            10,
          ).add(Duration(seconds: index)).toIso8601String(),
        ),
      );
    final controller = ClientController(agentService: service);
    addTearDown(controller.dispose);
    controller.selectedConversationAgentId = 'codex';
    var structureNotifications = 0;
    final publishedLengths = <int>[];
    controller.conversationStructureListenable.addListener(() {
      structureNotifications += 1;
      publishedLengths.add(controller.selectedConversationSessions.length);
    });

    await controller.loadConversationSessions('codex');

    expect(controller.selectedConversationSessions, hasLength(10));
    expect(publishedLengths, [0, 3, 10, 10]);
    expect(structureNotifications, 4);
  });

  test(
    'head refresh preserves every loaded paging row before the next offset',
    () async {
      final sessions = List.generate(
        120,
        (index) => conversationSessionJson(
          id: 'native-codex-$index',
          agentId: 'codex',
          text: 'Native Codex history $index',
          updatedAt: DateTime.utc(
            2026,
            7,
            10,
          ).subtract(Duration(seconds: index)).toIso8601String(),
        ),
      );
      final service = FakeAgentService()
        ..conversationSessions['codex'] = sessions;
      final controller = ClientController(agentService: service);
      addTearDown(controller.dispose);
      controller.selectedConversationAgentId = 'codex';

      await controller.loadConversationSessions('codex');
      await controller.loadMoreConversationSessions('codex');
      expect(controller.selectedConversationSessions, hasLength(20));

      service.conversationSessions['codex'] = [
        conversationSessionJson(
          id: 'native-codex-new',
          agentId: 'codex',
          text: 'New native Codex history',
          updatedAt: '2026-07-11T00:00:00Z',
        ),
        ...sessions,
      ];
      await controller.refreshConversationSessions('codex');

      expect(controller.selectedConversationSessions, hasLength(21));
      expect(
        controller.selectedConversationSessions.map((session) => session.id),
        containsAll([
          'native-codex-new',
          for (var index = 0; index < 20; index += 1) 'native-codex-$index',
        ]),
      );

      await controller.loadMoreConversationSessions('codex');

      expect(service.cliCalls.last, [
        'conversations',
        'stream',
        '--agent',
        'codex',
        '--limit',
        '21',
        '--offset',
        '21',
      ]);
      expect(controller.selectedConversationSessions, hasLength(41));
      expect(
        controller.selectedConversationSessions.map((session) => session.id),
        containsAll([
          'native-codex-new',
          for (var index = 0; index < 40; index += 1) 'native-codex-$index',
        ]),
      );
    },
  );

  test(
    'background refresh inserts newer history without stealing selection',
    () async {
      final service = FakeAgentService()
        ..conversationSessions['codex'] = [
          conversationSessionJson(
            id: 'native-codex-old',
            agentId: 'codex',
            text: 'Older native Codex history',
            updatedAt: '2026-06-12T00:00:01Z',
          ),
        ];
      final controller = ClientController(agentService: service);
      addTearDown(controller.dispose);

      controller.selectedConversationAgentId = 'codex';
      await controller.loadConversationSessions('codex');

      expect(controller.isLoadingConversations, isFalse);
      expect(service.conversationStreamCalls, 1);
      expect(
        controller.selectedConversationSessions.map((session) => session.id),
        ['native-codex-old'],
      );

      service.conversationSessions['codex'] = [
        conversationSessionJson(
          id: 'native-codex-new',
          agentId: 'codex',
          text: 'Newer native Codex history',
          updatedAt: '2026-06-14T00:00:01Z',
        ),
        conversationSessionJson(
          id: 'native-codex-old',
          agentId: 'codex',
          text: 'Older native Codex history',
          updatedAt: '2026-06-12T00:00:01Z',
        ),
      ];
      controller.currentSection = ClientSection.agents;
      var structureNotifications = 0;
      var activeNotifications = 0;
      controller.conversationStructureListenable.addListener(
        () => structureNotifications += 1,
      );
      controller.activeConversationListenable.addListener(
        () => activeNotifications += 1,
      );

      await controller.refreshConversationSessions('codex');

      expect(controller.isLoadingConversations, isFalse);
      expect(service.conversationStreamCalls, 2);
      expect(
        controller.selectedConversationSessions.map((session) => session.id),
        ['native-codex-new', 'native-codex-old'],
      );
      expect(controller.selectedConversationSession?.id, 'native-codex-old');
      expect(structureNotifications, 1);
      expect(activeNotifications, 0);
    },
  );

  test(
    'Codex runtime facts keep refreshing without a selected direct agent',
    () async {
      final service = FakeAgentService()
        ..conversationSessions['codex'] = [
          conversationSessionJson(
            id: 'native-codex-active',
            agentId: 'codex',
            text: 'External Codex task',
          ),
        ];
      final controller = ClientController(
        agentService: service,
        conversationRefreshPolicy: const ConversationRefreshPolicy(
          activeInterval: Duration(seconds: 1),
          warmInterval: Duration(seconds: 1),
          backgroundInterval: Duration(seconds: 1),
          activeCatalogInterval: Duration(milliseconds: 8),
          warmCatalogInterval: Duration(milliseconds: 20),
          backgroundCatalogInterval: Duration(milliseconds: 40),
        ),
      );
      addTearDown(controller.dispose);
      controller.scannedTargets = [
        TargetCandidate(
          target: 'codex',
          label: 'Codex',
          kind: 'cli',
          status: 'detected',
          configured: true,
          confidence: 1,
          adapterStatus: 'implemented',
        ),
      ];
      await controller.lifecycleController.initialize(
        sequentialSteps: const [],
      );
      controller.currentSection = ClientSection.agents;

      await controller.refreshConversationSessions('codex');
      expect(controller.selectedConversationAgentId, isEmpty);
      expect(
        controller.conversationSessionsByAgent['codex']?.single.running,
        isFalse,
      );

      service.conversationSessions['codex'] = [
        conversationSessionJson(
          id: 'native-codex-active',
          agentId: 'codex',
          text: 'External Codex task',
          running: true,
        ),
      ];
      var structureNotifications = 0;
      controller.conversationStructureListenable.addListener(
        () => structureNotifications += 1,
      );
      controller.conversationAttentionContextChanged(immediateActive: true);
      await _waitForHistoryRefresh(
        () =>
            controller.conversationSessionsByAgent['codex']?.single.running ==
            true,
      );

      expect(controller.selectedConversationAgentId, isEmpty);
      expect(
        controller.conversationSessionsByAgent['codex']?.single.running,
        isTrue,
      );
      expect(structureNotifications, 1);
    },
  );

  test('conversation refresh priority follows view attention', () {
    final controller = ClientController(agentService: FakeAgentService());
    addTearDown(controller.dispose);
    controller.currentSection = ClientSection.agents;

    expect(
      controller.conversationRefreshPriority,
      ConversationRefreshPriority.active,
    );

    controller.updateConversationAttention(viewFocused: false);
    expect(
      controller.conversationRefreshPriority,
      ConversationRefreshPriority.warm,
    );

    controller.currentSection = ClientSection.settings;
    controller.updateConversationAttention(viewFocused: true);
    expect(
      controller.conversationRefreshPriority,
      ConversationRefreshPriority.background,
    );

    controller.updateConversationAttention(
      lifecycleState: AppLifecycleState.hidden,
    );
    expect(
      controller.conversationRefreshPriority,
      ConversationRefreshPriority.suspended,
    );
  });

  test(
    'focused scheduler uses exact-session refresh and hidden state suspends it',
    () async {
      final service = FakeAgentService()
        ..conversationSessions['codex'] = [
          conversationSessionJson(
            id: 'native-codex-active',
            agentId: 'codex',
            text: 'Focused native history',
          ),
        ];
      final controller = ClientController(
        agentService: service,
        conversationRefreshPolicy: const ConversationRefreshPolicy(
          activeInterval: Duration(milliseconds: 8),
          warmInterval: Duration(milliseconds: 40),
          backgroundInterval: Duration(milliseconds: 80),
          activeCatalogInterval: Duration(seconds: 1),
          warmCatalogInterval: Duration(seconds: 1),
          backgroundCatalogInterval: Duration(seconds: 1),
        ),
      );
      addTearDown(controller.dispose);
      await controller.lifecycleController.initialize(
        sequentialSteps: const [],
      );
      controller.currentSection = ClientSection.agents;
      controller.selectedConversationAgentId = 'codex';
      await controller.loadConversationSessions('codex');
      service.conversationStreamCalls = 0;
      service.cliCalls = const [];
      service.conversationStdinRequests = const [];
      var activeNotifications = 0;
      var structureNotifications = 0;
      var globalNotifications = 0;
      controller.activeConversationListenable.addListener(
        () => activeNotifications += 1,
      );
      controller.conversationStructureListenable.addListener(
        () => structureNotifications += 1,
      );
      controller.addListener(() => globalNotifications += 1);

      await _waitForHistoryRefresh(() => service.conversationStreamCalls >= 1);

      expect(service.conversationStreamCalls, greaterThanOrEqualTo(1));
      expect(
        service.conversationStdinRequests.any(
          (request) =>
              request['sessionId'] == 'native-codex-active' &&
              request['limit'] == 1 &&
              request['messageLimit'] == 50,
        ),
        isTrue,
      );
      expect(activeNotifications, 0);
      expect(structureNotifications, 0);
      expect(globalNotifications, 0);

      service.conversationSessions['codex'] = [
        conversationSessionJson(
          id: 'native-codex-active',
          agentId: 'codex',
          text: 'Updated focused native history',
          updatedAt: '2026-07-10T00:00:03Z',
        ),
      ];
      await _waitForHistoryRefresh(() => activeNotifications == 1);

      expect(activeNotifications, 1);
      expect(structureNotifications, 0);
      expect(globalNotifications, 0);
      expect(
        controller.selectedConversationSession?.messages.first.text,
        'Updated focused native history',
      );

      controller.updateConversationAttention(
        lifecycleState: AppLifecycleState.hidden,
      );
      await Future<void>.delayed(const Duration(milliseconds: 15));
      final callsWhileHidden = service.conversationStreamCalls;
      await Future<void>.delayed(const Duration(milliseconds: 35));
      expect(service.conversationStreamCalls, callsWhileHidden);

      controller.updateConversationAttention(
        lifecycleState: AppLifecycleState.resumed,
        viewFocused: true,
      );
      await _waitForHistoryRefresh(
        () => service.conversationStreamCalls > callsWhileHidden,
      );
      expect(service.conversationStreamCalls, greaterThan(callsWhileHidden));
    },
  );

  test(
    'open native-history session live-echoes appended turns without forking identities',
    () async {
      const uuidA = '7bb7b109-f089-4529-a6c9-2c019a71c106';
      const uuidB = '2f7230ca-e675-4846-a922-1104cf0a1854';
      final service = FakeAgentService()
        ..conversationSessions['antigravity'] = [
          conversationSessionJson(
            id: 'ag-transcript',
            nativeSessionId: uuidA,
            agentId: 'antigravity',
            text: 'IDE conversation turn one',
            updatedAt: '2026-07-31T08:18:32Z',
          ),
          conversationSessionJson(
            id: 'ag-cli',
            nativeSessionId: uuidB,
            agentId: 'antigravity',
            text: 'CLI conversation turn one',
            updatedAt: '2026-07-31T08:04:37Z',
          ),
        ];
      final controller = ClientController(
        agentService: service,
        conversationRefreshPolicy: const ConversationRefreshPolicy(
          activeInterval: Duration(milliseconds: 8),
          warmInterval: Duration(milliseconds: 40),
          backgroundInterval: Duration(milliseconds: 60),
          activeCatalogInterval: Duration(milliseconds: 60),
          warmCatalogInterval: Duration(milliseconds: 60),
          backgroundCatalogInterval: Duration(milliseconds: 60),
        ),
      );
      addTearDown(controller.dispose);
      await controller.lifecycleController.initialize(
        sequentialSteps: const [],
      );
      controller.currentSection = ClientSection.agents;
      controller.selectedConversationAgentId = 'antigravity';
      await controller.loadConversationSessions('antigravity');

      // Distinct native identities keep both conversations visible.
      expect(
        controller.selectedConversationSessions.map((session) => session.id),
        ['ag-transcript', 'ag-cli'],
      );
      controller.selectConversationSession('ag-transcript');
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // The native store gains a turn: the open transcript appends in place,
      // and a duplicate projection of the same conversation appears.
      service.conversationSessions['antigravity'] = [
        conversationSessionJson(
          id: 'ag-transcript',
          nativeSessionId: uuidA,
          agentId: 'antigravity',
          text: 'IDE conversation turn two',
          updatedAt: '2026-07-31T08:24:32Z',
        ),
        conversationSessionJson(
          id: 'ag-transcript-full',
          nativeSessionId: uuidA,
          agentId: 'antigravity',
          text: 'IDE conversation turn two',
          updatedAt: '2026-07-31T08:24:32Z',
        ),
        conversationSessionJson(
          id: 'ag-cli',
          nativeSessionId: uuidB,
          agentId: 'antigravity',
          text: 'CLI conversation turn one',
          updatedAt: '2026-07-31T08:04:37Z',
        ),
      ];
      Future<void> until(bool Function() condition) async {
        for (var attempt = 0; attempt < 100; attempt += 1) {
          if (condition()) {
            return;
          }
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(condition(), isTrue);
      }

      // The open conversation live-echoes the appended turn.
      await until(
        () =>
            controller.selectedConversationSession?.messages
                .map((message) => message.text)
                .join(' ')
                .contains('IDE conversation turn two') ??
            false,
      );
      // The duplicate projection of the same native conversation collapses
      // instead of forking the list; the other conversation stays distinct.
      await until(
        () =>
            controller.selectedConversationSessions
                .where((session) => session.nativeSessionId == uuidA)
                .length ==
            1,
      );
      expect(
        controller.selectedConversationSessions.where(
          (session) => session.nativeSessionId == uuidB,
        ),
        hasLength(1),
      );

      // Leaving the agents destination drops the live echo to the bounded
      // background cadence instead of the focused one.
      controller.currentSection = ClientSection.settings;
      expect(
        controller.conversationRefreshPriority,
        ConversationRefreshPriority.background,
      );
      controller.updateConversationAttention(
        lifecycleState: AppLifecycleState.hidden,
      );
      expect(
        controller.conversationRefreshPriority,
        ConversationRefreshPriority.suspended,
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final callsBeforeSuspend = service.conversationStreamCalls;
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(service.conversationStreamCalls, callsBeforeSuspend);
    },
  );

  test(
    'new foreground agent load is not blocked by an older agent request',
    () async {
      final codexGate = Completer<void>();
      final service = FakeAgentService()
        ..conversationStreamGates['codex'] = codexGate
        ..conversationSessions['codex'] = [
          conversationSessionJson(
            id: 'codex-session',
            agentId: 'codex',
            text: 'Codex history',
          ),
        ]
        ..conversationSessions['opencode'] = [
          conversationSessionJson(
            id: 'opencode-session',
            agentId: 'opencode',
            text: 'OpenCode history',
          ),
        ];
      final controller = ClientController(agentService: service);
      addTearDown(controller.dispose);

      final codexLoad = controller.selectConversationAgent('codex');
      await Future<void>.delayed(Duration.zero);
      await controller.selectConversationAgent('opencode');

      expect(controller.selectedConversationAgentId, 'opencode');
      expect(controller.selectedConversationSession, isNull);
      expect(controller.isLoadingConversations, isFalse);

      codexGate.complete();
      await codexLoad;

      expect(controller.selectedConversationAgentId, 'opencode');
      expect(controller.selectedConversationSession, isNull);
      expect(controller.conversationSessionsByAgent['codex'], hasLength(1));
    },
  );
}

Future<void> _waitForHistoryRefresh(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('history refresh did not settle');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
