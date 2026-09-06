import 'support/client_controller_scenario_dependencies.dart';
import 'support/client_controller_scenario_json.dart';
import 'support/fake_agent_service.dart';
import 'support/fake_mobile_relay_service.dart';

void registerClientMobileHistoryScenarios() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'mobile agent selection loads native sessions and resumes the exact id',
    () async {
      final agentService = FakeAgentService();
      final relayService = FakeMobileRelayService()
        ..secureAgentSessions['codex'] = [
          conversationSessionJson(
            id: 'codex-projection-new',
            nativeSessionId: 'codex-native-new',
            agentId: 'codex',
            text: 'New native conversation',
            updatedAt: '2026-07-10T00:00:02Z',
          ),
          conversationSessionJson(
            id: 'codex-projection-exact',
            nativeSessionId: 'codex-native-exact',
            agentId: 'codex',
            text: 'Exact native conversation',
            updatedAt: '2026-07-10T00:00:01Z',
          ),
        ];
      final controller = ClientController(
        agentService: agentService,
        mobileRelayService: relayService,
        mobileClientRuntimePlatformOverride: true,
      );
      addTearDown(controller.dispose);
      controller.scannedTargets = [
        TargetCandidate(
          target: 'codex',
          label: 'Codex',
          kind: 'cli',
          status: 'detected',
          configured: true,
          confidence: 0.9,
          binaryPath: '/test-bin/codex',
          adapterStatus: 'implemented',
          adapterCapabilities: parityReadyAdapterCapabilities,
          supportedActions: const ['runtime.message.send'],
        ),
      ];

      await controller.selectConversationAgent('codex');

      expect(relayService.secureAgentSessionListCalls, 1);
      expect(relayService.lastSecureAgentSessionListAgentId, 'codex');
      expect(relayService.lastSecureAgentSessionListLimit, 20);
      expect(agentService.conversationStreamCalls, 0);
      expect(agentService.conversationListCalls, 0);
      expect(controller.selectedConversationSessions, hasLength(2));
      expect(
        controller.selectedConversationSessions.last.nativeSessionId,
        'codex-native-exact',
      );

      controller.selectConversationSession('codex-projection-exact');
      await controller.sendConversationMessage('Continue this exact thread');

      expect(relayService.secureAgentMessageCalls, 1);
      expect(relayService.lastAgentSessionId, 'codex-native-exact');
      expect(controller.selectedConversationSessions, hasLength(2));
      expect(
        controller.selectedConversationSession?.id,
        'codex-projection-exact',
      );
      expect(
        controller.selectedConversationSession?.nativeSessionId,
        'codex-native-exact',
      );
      expect(agentService.conversationAppendCalls, 0);
    },
  );

  test(
    'mobile session history paginates beyond the first Secure Mesh page',
    () async {
      final sessions = List<Map<String, dynamic>>.generate(
        25,
        (index) => conversationSessionJson(
          id: 'codex-projection-$index',
          nativeSessionId: 'codex-native-$index',
          agentId: 'codex',
          text: 'Native conversation $index',
          updatedAt: '2026-07-10T00:${index.toString().padLeft(2, '0')}:00Z',
        ),
      );
      final relayService = FakeMobileRelayService()
        ..secureAgentSessions['codex'] = sessions;
      final controller = ClientController(
        agentService: FakeAgentService(),
        mobileRelayService: relayService,
        mobileClientRuntimePlatformOverride: true,
      );
      addTearDown(controller.dispose);
      controller.scannedTargets = [
        TargetCandidate(
          target: 'codex',
          label: 'Codex',
          kind: 'cli',
          status: 'detected',
          configured: true,
          confidence: 0.9,
          binaryPath: '/test-bin/codex',
          adapterStatus: 'implemented',
          adapterCapabilities: parityReadyAdapterCapabilities,
          supportedActions: const ['runtime.message.send'],
        ),
      ];

      await controller.selectConversationAgent('codex');

      expect(relayService.secureAgentSessionListCalls, 1);
      expect(relayService.lastSecureAgentSessionListOffset, 0);
      expect(controller.selectedConversationSessions, hasLength(20));
      expect(controller.selectedConversationSessionsHasMore, isTrue);

      await controller.loadMoreConversationSessions('codex');

      expect(relayService.secureAgentSessionListCalls, 2);
      expect(relayService.lastSecureAgentSessionListOffset, 20);
      expect(controller.selectedConversationSessions, hasLength(25));
      expect(controller.selectedConversationSessionsHasMore, isFalse);
      expect(
        controller.functionalStatusRuntime.messageEnglish,
        contains('Read 25 native codex sessions.'),
      );
    },
  );

  test(
    'mobile exact session selection uses describe when absent from first page',
    () async {
      final exact = conversationSessionJson(
        id: 'codex-projection-exact',
        nativeSessionId: 'codex-native-exact',
        agentId: 'codex',
        text: 'Exact older conversation',
        updatedAt: '2026-07-09T00:00:00Z',
      );
      final relayService = FakeMobileRelayService()
        ..secureAgentSessions['codex'] = [
          conversationSessionJson(
            id: 'codex-projection-new',
            nativeSessionId: 'codex-native-new',
            agentId: 'codex',
            text: 'New native conversation',
            updatedAt: '2026-07-10T00:00:02Z',
          ),
        ]
        ..secureAgentSessionDescriptions['codex-native-exact'] = exact;
      final controller = ClientController(
        agentService: FakeAgentService(),
        mobileRelayService: relayService,
        mobileClientRuntimePlatformOverride: true,
      );
      addTearDown(controller.dispose);
      controller.scannedTargets = [
        TargetCandidate(
          target: 'codex',
          label: 'Codex',
          kind: 'cli',
          status: 'detected',
          configured: true,
          confidence: 0.9,
          binaryPath: '/test-bin/codex',
          adapterStatus: 'implemented',
          adapterCapabilities: parityReadyAdapterCapabilities,
          supportedActions: const ['runtime.message.send'],
        ),
      ];
      controller.selectedConversationAgentId = 'codex';
      controller.selectedConversationSessionId = 'codex-projection-exact';
      controller.conversationSessionsByAgent = {
        'codex': [AgentConversationSession.fromJson(exact)],
      };

      await controller.loadConversationSessions('codex');

      expect(relayService.secureAgentSessionListCalls, 1);
      expect(relayService.secureAgentSessionDescribeCalls, 1);
      expect(
        relayService.lastSecureAgentSessionDescribeSessionId,
        'codex-native-exact',
      );
      expect(
        controller.selectedConversationSession?.nativeSessionId,
        'codex-native-exact',
      );
      expect(controller.selectedConversationSessions, hasLength(2));
    },
  );

  test(
    'mobile native session load fails closed without latest fallback',
    () async {
      final relayService = FakeMobileRelayService()
        ..secureAgentSessionListResult = const {
          'ok': false,
          'errorCode': 'secure_agent_sessions_denied',
          'error': 'private-native-history-canary',
        };
      final controller = ClientController(
        agentService: FakeAgentService(),
        mobileRelayService: relayService,
        mobileClientRuntimePlatformOverride: true,
      );
      addTearDown(controller.dispose);
      controller.scannedTargets = [
        TargetCandidate(
          target: 'codex',
          label: 'Codex',
          kind: 'cli',
          status: 'detected',
          configured: true,
          confidence: 0.9,
          binaryPath: '/test-bin/codex',
          adapterStatus: 'implemented',
          adapterCapabilities: parityReadyAdapterCapabilities,
          supportedActions: const ['runtime.message.send'],
        ),
      ];
      controller.selectedConversationAgentId = 'codex';
      controller.selectedConversationSessionId = 'stale-projection';
      controller.conversationSessionsByAgent = {
        'codex': [
          AgentConversationSession.fromJson(
            conversationSessionJson(
              id: 'stale-projection',
              nativeSessionId: 'stale-native-session',
              agentId: 'codex',
              text: 'Stale native history',
            ),
          ),
        ],
      };

      await controller.loadConversationSessions('codex');

      expect(relayService.secureAgentSessionListCalls, 1);
      expect(controller.selectedConversationSessions, isEmpty);
      expect(controller.selectedConversationSession, isNull);
      expect(controller.selectedConversationSessionId, 'stale-projection');
      expect(controller.lastError, 'secure_agent_sessions_denied');
      expect(controller.lastError, isNot(contains('private-native-history')));
      expect(controller.statusMessage, contains('未选择其他会话'));

      await controller.sendConversationMessage('must not create a new thread');

      expect(relayService.secureAgentMessageCalls, 0);
      expect(controller.lastError, 'native_session_unresolved');
    },
  );
}
