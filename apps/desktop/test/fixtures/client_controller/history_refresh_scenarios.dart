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
    'loadConversationSessions reveals native history in pages of fifty',
    () async {
      final pagedSessions = List.generate(120, (index) {
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
        '51',
      ]);
      expect(controller.selectedConversationSessions, hasLength(50));
      expect(
        controller.selectedConversationSessions.first.id,
        'native-codex-000',
      );
      expect(
        controller.selectedConversationSessions.last.id,
        'native-codex-049',
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
        '51',
        '--offset',
        '50',
      ]);
      expect(controller.selectedConversationSessions, hasLength(100));
      expect(
        controller.selectedConversationSessions.last.id,
        'native-codex-099',
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
        '51',
        '--offset',
        '100',
      ]);
      expect(controller.selectedConversationSessions, hasLength(120));
      expect(
        controller.selectedConversationSessions.last.id,
        'native-codex-119',
      );
      expect(controller.selectedConversationSessionsHasMore, isFalse);
    },
  );

  test(
    'streamed catalog publishes cumulative 3 10 20 milestones before completion',
    () async {
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

      expect(controller.selectedConversationSessions, hasLength(50));
      expect(publishedLengths, [0, 3, 10, 20, 50]);
      expect(structureNotifications, 5);
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

      await Future<void>.delayed(const Duration(milliseconds: 35));

      expect(service.conversationStreamCalls, greaterThanOrEqualTo(1));
      expect(
        service.cliCalls.any(
          (args) =>
              args.contains('--session-id') &&
              args.contains('native-codex-active') &&
              args.contains('--limit') &&
              args.contains('1'),
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
      await Future<void>.delayed(const Duration(milliseconds: 25));

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
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(service.conversationStreamCalls, greaterThan(callsWhileHidden));
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
