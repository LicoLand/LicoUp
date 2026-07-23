import 'fixtures/client_controller/support/client_controller_scenario_dependencies.dart';
import 'fixtures/client_controller/support/fake_agent_conversation_fixture.dart';
import 'fixtures/client_controller/support/fake_agent_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('native RPC failure keeps its stable stage code visible', () async {
    final service = FakeAgentService()
      ..runtimeMessageRpcErrorCode = 'invalid_response';
    final controller = ClientController(agentService: service);
    addTearDown(controller.dispose);

    await controller.scanTargets();
    await controller.selectConversationAgent('codex');
    await controller.sendConversationMessage('Synthetic failed turn');

    expect(controller.lastError, 'native_agent_invalid_response');
    expect(
      controller.conversationSendErrorFor('codex'),
      'native_agent_invalid_response',
    );
    expect(controller.isSendingConversationMessage, isFalse);
  });

  test('non-send controller errors are not presented as send failures', () {
    final controller = ClientController(agentService: FakeAgentService());
    addTearDown(controller.dispose);

    controller.lastError = 'target_scan_failed';

    expect(controller.conversationSendErrorFor('codex'), isEmpty);
  });

  test(
    'delayed native readback does not fail or disable a completed turn',
    () async {
      final service = FakeAgentService()
        ..runtimeSessionIdResult = 'synthetic-delayed-session'
        ..recordRuntimeMessageInHistory = false;
      final controller = ClientController(agentService: service);
      addTearDown(controller.dispose);

      await controller.scanTargets();
      await controller.selectConversationAgent('codex');
      controller.startNewConversationSession();
      await controller.sendConversationMessage('Synthetic successful turn');

      expect(controller.lastError, isEmpty);
      expect(controller.isSendingConversationMessage, isFalse);
      expect(
        controller.selectedConversationSession?.nativeSessionId,
        'synthetic-delayed-session',
      );

      await controller.sendConversationMessage('Synthetic continuation');
      expect(service.runtimeMessageCalls, 2);
      expect(controller.lastError, isEmpty);
    },
  );

  test(
    'completed turn readback cannot reclaim a newly prepared conversation',
    () async {
      final service = FakeAgentService()
        ..runtimeSessionIdResult = 'completed-session';
      final controller = ClientController(agentService: service);
      addTearDown(controller.dispose);

      await controller.scanTargets();
      await controller.selectConversationAgent('codex');
      final readbackGate = Completer<void>();
      service.conversationStreamGates['codex'] = readbackGate;

      controller.startNewConversationSession();
      await controller.sendConversationMessage('First conversation');
      expect(controller.selectedConversationSessionId, 'completed-session');

      controller.startNewConversationSession();
      expect(controller.preparingNewConversation, isTrue);
      expect(controller.selectedConversationSession, isNull);
      expect(controller.selectedLiveConversationMessages, isEmpty);

      readbackGate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(controller.preparingNewConversation, isTrue);
      expect(controller.selectedConversationSessionId, isEmpty);
      expect(controller.selectedConversationSession, isNull);

      service.conversationStreamGates.remove('codex');
      service.runtimeSessionIdResult = 'second-session';
      await controller.sendConversationMessage('Second conversation');

      expect(controller.selectedConversationSessionId, 'second-session');
      final secondMessages =
          controller.selectedConversationSession?.messages ?? const [];
      expect(
        secondMessages.any((message) => message.text == 'Second conversation'),
        isTrue,
      );
      expect(
        secondMessages.any((message) => message.text == 'First conversation'),
        isFalse,
      );
    },
  );

  test(
    'new conversation draft never inherits a refreshed previous session id',
    () async {
      final service = FakeAgentService()
        ..conversationSessions['codex'] = [
          buildFakeConversationSession(
            id: 'previous-session',
            agentId: 'claude-code',
            agentLabel: 'Claude Code',
            text: 'Previous conversation',
          )..['nativeSessionId'] = 'previous-session',
        ]
        ..runtimeSessionIdResult = 'brand-new-session'
        ..recordRuntimeMessageInHistory = false;
      final controller = ClientController(agentService: service);
      addTearDown(controller.dispose);

      await controller.scanTargets();
      await controller.selectConversationAgent('codex');
      controller.startNewConversationSession();

      // Simulate a late catalog reconciliation writing the previous selection.
      // The draft token remains the sole authority for the first send.
      controller.selectedConversationSessionId = 'previous-session';
      expect(controller.preparingNewConversation, isTrue);
      expect(controller.selectedConversationSession, isNull);

      await controller.sendConversationMessage('Brand new conversation');

      expect(service.runtimeMessageCalls, 1);
      expect(service.lastRuntimeMessageRequest['sessionId'], isNull);
      expect(controller.selectedConversationSessionId, 'brand-new-session');

      await controller.refreshConversationCatalogInternal(
        'codex',
        foreground: true,
      );

      expect(
        controller.selectedConversationSessions.map(
          (session) => session.nativeSessionId,
        ),
        contains('brand-new-session'),
      );
      expect(controller.selectedConversationSessionId, 'brand-new-session');
      expect(controller.preparingNewConversation, isFalse);
      expect(
        controller.selectedConversationSession?.messages.any(
          (message) => message.text == 'Previous conversation',
        ),
        isFalse,
      );
    },
  );
}
