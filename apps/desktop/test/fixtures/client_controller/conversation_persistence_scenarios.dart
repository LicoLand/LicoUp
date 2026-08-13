import 'package:licoup/src/application/features/agents/conversation/conversation_session_state_controller.dart';

import 'support/client_controller_scenario_dependencies.dart';
import 'support/fake_agent_service.dart';

void registerClientConversationPersistenceScenarios() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('persists native title upgrades across restart', () async {
    final directory = await Directory.systemTemp.createTemp(
      'lico-agent-conversation-projection-',
    );
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });
    final portableData = PortableDataRoot(dataDirectoryOverride: directory);
    final controller = ClientController(
      portableData: portableData,
      agentService: FakeAgentService(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    final saved = await controller.conversationCommitTurnBoundNativeReadback(
      agentId: 'codex',
      nativeSessionId: 'synthetic-persisted-session',
      mergeWithSelectedSession: false,
      messages: const [
        AgentConversationMessage(
          id: 'synthetic-user',
          role: 'user',
          text: 'Persist this conversation',
          createdAt: '2026-07-27T00:00:00.000Z',
        ),
        AgentConversationMessage(
          id: 'synthetic-assistant',
          role: 'assistant',
          text: 'Synthetic persisted response',
          createdAt: '2026-07-27T00:00:01.000Z',
        ),
      ],
    );
    expect(saved, isTrue);

    final projected = controller.conversationSessionsByAgent['codex']!.single;
    final nativeSummary = AgentConversationSession.fromJson({
      ...projected.toJson(),
      'title': 'Persisted conversation summary',
    });
    controller.conversationCommitCatalog(
      'codex',
      ConversationSessionPage(sessions: [nativeSummary], hasMore: false),
      replaceAll: true,
      updateStatus: false,
    );
    await controller.conversationFlushProjectionPersistence();
    expect(
      controller.conversationSessionsByAgent['codex']?.single.title,
      'Persisted conversation summary',
    );

    controller.conversationCommitCatalog(
      'codex',
      ConversationSessionPage(
        sessions: [AgentConversationSession.fromJson(projected.toJson())],
        hasMore: false,
      ),
      replaceAll: true,
      updateStatus: false,
    );
    await controller.conversationFlushProjectionPersistence();
    expect(
      controller.conversationSessionsByAgent['codex']?.single.title,
      'Persisted conversation summary',
    );

    final reloaded = ClientController(
      portableData: portableData,
      agentService: FakeAgentService()..recordRuntimeMessageInHistory = false,
    );
    addTearDown(reloaded.dispose);
    await reloaded.initialize();

    final restored = reloaded.conversationSessionsByAgent['codex'] ?? const [];
    expect(restored, hasLength(1));
    expect(restored.single.title, 'Persisted conversation summary');
    expect(
      restored.single.messages.map((message) => message.role),
      containsAll(<String>['user', 'assistant']),
    );
  });
}
