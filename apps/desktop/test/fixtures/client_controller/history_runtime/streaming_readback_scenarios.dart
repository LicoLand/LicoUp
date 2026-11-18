import '../support/client_controller_scenario_dependencies.dart';
import '../support/client_controller_scenario_json.dart';
import '../support/fake_agent_service.dart';

const _respondingLifecyclePrefix = [
  'submitted',
  'accepted',
  'processing',
  'responding',
];
const _completedLifecyclePrefix = [
  'submitted',
  'accepted',
  'processing',
  'responding',
  'completed',
];

void registerClientHistoryRuntimeStreamingReadbackScenarios() {
  test(
    'completed streamed reply remains visible until native history catches up',
    () async {
      final staleSession = conversationSessionJson(
        id: 'claude-native-session',
        nativeSessionId: 'claude-native-session',
        agentId: 'claude-code',
        text: 'Existing native history',
      );
      final service = FakeAgentService()
        ..scanTargetsResult = [
          TargetCandidate(
            target: 'claude-code',
            label: 'Claude Code',
            kind: 'cli',
            status: 'detected',
            configured: true,
            confidence: 1,
            binaryPath: '/synthetic/bin/claude',
            adapterStatus: 'implemented',
            adapterCapabilities: parityReadyAdapterCapabilities,
            supportedActions: const ['runtime.message.send'],
          ),
        ]
        ..conversationSessions['claude-code'] = [staleSession]
        ..runtimeSessionIdResult = 'claude-native-session'
        ..runtimeNativeSessionIdResult = 'claude-native-session'
        ..runtimeMessageStreamEventQueue = [
          [
            {
              'event': 'agent.message.completed',
              'payload': {
                'text': 'Synthetic Claude reply',
                'lifecyclePrefix': _respondingLifecyclePrefix,
              },
            },
          ],
        ]
        ..runtimeMessageResultQueue = [
          {
            'lifecyclePrefix': _completedLifecyclePrefix,
            'terminalTransition': {'kind': 'lifecycle', 'stage': 'completed'},
          },
        ]
        ..recordRuntimeMessageInHistory = false;
      final controller = ClientController(agentService: service);
      addTearDown(controller.dispose);

      await controller.scanTargets();
      await controller.selectConversationAgent('claude-code');
      controller.selectConversationSession('claude-native-session');

      await controller.sendConversationMessage('Synthetic Claude prompt');
      expect(
        controller.selectedLiveConversationMessages
            .where((message) => message.role == 'assistant')
            .map((message) => message.text),
        contains('Synthetic Claude reply'),
      );
      expect(
        controller.selectedConversationSession?.messages
            .where((message) => message.role == 'assistant')
            .map((message) => message.text),
        contains('Synthetic Claude reply'),
        reason: 'turn-bound reply must be committed before provider refresh',
      );
      await controller.refreshConversationSessions('claude-code');
      expect(
        controller.selectedConversationSession?.messages
            .where((message) => message.role == 'assistant')
            .map((message) => message.text),
        contains('Synthetic Claude reply'),
        reason: 'same-id provider history must not replace a newer reply',
      );

      service.conversationSessions['claude-code'] = [
        {
          ...staleSession,
          'messages': [
            ...(staleSession['messages'] as List),
            {
              'id': 'persisted-user',
              'role': 'user',
              'text': 'Synthetic Claude prompt',
            },
            {
              'id': 'persisted-assistant',
              'role': 'assistant',
              'text': 'Synthetic Claude reply',
            },
          ],
        },
      ];

      await controller.refreshConversationSessions('claude-code');
      expect(controller.selectedLiveConversationMessages, isEmpty);
      expect(
        controller.selectedConversationSession?.messages
            .where((message) => message.role == 'assistant')
            .map((message) => message.text),
        contains('Synthetic Claude reply'),
      );
    },
  );
}
