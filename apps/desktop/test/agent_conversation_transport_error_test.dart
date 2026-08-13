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

  test('lifecycle updates stay between the request and reply', () {
    final controller = ClientController(agentService: FakeAgentService());
    addTearDown(controller.dispose);

    controller.conversationStartLiveProjection(
      scopeKey: 'draft:codex:turn-1',
      turnId: 'turn-1',
      userText: 'Request',
    );
    controller.conversationUpsertLiveReply(
      scopeKey: 'draft:codex:turn-1',
      turnId: 'turn-1',
      text: 'Reply',
    );
    controller.conversationUpsertLiveLifecycle(
      scopeKey: 'draft:codex:turn-1',
      turnId: 'turn-1',
      stage: 'completed',
    );

    expect(
      controller.liveConversationMessagesByScope['draft:codex:turn-1']!.map(
        (message) => message.id,
      ),
      ['turn-1-user', 'turn-1-lifecycle', 'turn-1-assistant'],
    );
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
    'cursor IDE history send injects one-time handoff and clears sessionId',
    () async {
      final ideSession =
          buildFakeConversationSession(
              id: 'ide-composer-1',
              agentId: 'cursor',
              agentLabel: 'Cursor',
              text: 'Earlier IDE user turn',
            )
            ..['nativeSessionId'] = 'ide-composer-1'
            ..['sourceKind'] = 'cursor-global-storage'
            ..['sourcePath'] =
                '/fixture-root/Cursor/User/globalStorage/state.vscdb'
            ..['messages'] = [
              {
                'id': 'msg-user-ide',
                'role': 'user',
                'text': 'Earlier IDE user turn',
                'createdAt': '2026-08-06T00:00:00Z',
              },
              {
                'id': 'msg-agent-ide',
                'role': 'assistant',
                'text': 'Last IDE return about quota fallback.',
                'createdAt': '2026-08-06T00:00:01Z',
              },
            ];
      final service = FakeAgentService()
        ..scanTargetsResult = [_cursorTarget(runtimeBound: true)]
        ..conversationSessions['cursor'] = [ideSession];
      final controller = ClientController(agentService: service);
      addTearDown(controller.dispose);

      await controller.scanTargets();
      await controller.selectConversationAgent('cursor');
      await controller.refreshConversationCatalogInternal(
        'cursor',
        foreground: true,
      );
      controller.selectConversationSession('ide-composer-1');

      await controller.sendConversationMessage('Continue from IDE');
      await _settleAsyncProjection();

      expect(service.runtimeMessageCalls, 1);
      final firstText = (service.runtimeMessageRequests.first['text'] ?? '')
          .toString();
      expect(firstText, contains('[LicoUp IDE→CLI handoff — once]'));
      expect(firstText, contains('composerSessionId: ide-composer-1'));
      expect(firstText, contains('Last IDE return about quota fallback.'));
      expect(firstText, contains('Continue from IDE'));
      expect(service.runtimeMessageRequests.first['sessionId'], isNull);
      expect(
        controller.cursorIdeCliHandoffComposerIds.contains('ide-composer-1'),
        isTrue,
      );

      await controller.sendConversationMessage('Second CLI turn');
      expect(service.runtimeMessageCalls, 2);
      final secondText = (service.runtimeMessageRequests.last['text'] ?? '')
          .toString();
      expect(secondText, isNot(contains('[LicoUp IDE→CLI handoff — once]')));
      expect(secondText, 'Second CLI turn');
    },
  );

  test('cursor IDE handoff survives a failed first send for retry', () async {
    final ideSession =
        buildFakeConversationSession(
            id: 'ide-composer-2',
            agentId: 'cursor',
            agentLabel: 'Cursor',
            text: 'IDE history',
          )
          ..['nativeSessionId'] = 'ide-composer-2'
          ..['sourceKind'] = 'cursor-workspace-storage'
          ..['sourcePath'] = '/fixture-root/workspace/state.vscdb'
          ..['messages'] = [
            {
              'id': 'a1',
              'role': 'assistant',
              'text': 'Prior IDE assistant text',
              'createdAt': '2026-08-06T00:00:01Z',
            },
          ];
    final service = FakeAgentService()
      ..scanTargetsResult = [_cursorTarget(runtimeBound: true)]
      ..conversationSessions['cursor'] = [ideSession]
      ..runtimeMessageResultQueue = [
        {
          'ok': false,
          'error': {
            'code': 'authorization_denied',
            'message': 'Sign in required.',
          },
        },
      ];
    final controller = ClientController(agentService: service);
    addTearDown(controller.dispose);

    await controller.scanTargets();
    await controller.selectConversationAgent('cursor');
    await controller.refreshConversationCatalogInternal(
      'cursor',
      foreground: true,
    );
    controller.selectConversationSession('ide-composer-2');

    await controller.sendConversationMessage('First attempt');
    expect(service.runtimeMessageCalls, 1);
    expect(
      controller.cursorIdeCliHandoffComposerIds.contains('ide-composer-2'),
      isFalse,
    );

    await controller.sendConversationMessage('Retry attempt');
    expect(service.runtimeMessageCalls, 2);
    final retryText = (service.runtimeMessageRequests.last['text'] ?? '')
        .toString();
    expect(retryText, contains('[LicoUp IDE→CLI handoff — once]'));
    expect(retryText, contains('Prior IDE assistant text'));
    expect(retryText, contains('Retry attempt'));
    expect(
      controller.cursorIdeCliHandoffComposerIds.contains('ide-composer-2'),
      isTrue,
    );
  });

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

Future<void> _settleAsyncProjection() async {
  for (var index = 0; index < 8; index += 1) {
    await Future<void>.delayed(Duration.zero);
  }
}

TargetCandidate _cursorTarget({required bool runtimeBound}) {
  return TargetCandidate(
    target: 'cursor',
    label: 'Cursor',
    kind: 'cli',
    status: 'detected',
    configured: true,
    confidence: 1,
    binaryPath: runtimeBound ? '/synthetic/bin/cursor-agent' : null,
    adapterStatus: 'implemented',
    adapterCapabilities: const <String, dynamic>{
      'conversationDriver': 'implemented',
      'conversationProtocol': 'cursor-agent-cli-v1',
      'conversationReadiness': 'ready',
    },
    supportedActions: const ['runtime.message.send'],
  );
}
