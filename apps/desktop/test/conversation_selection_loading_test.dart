import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/application/features/agents/conversation/conversation_session_state_controller.dart';

import 'fixtures/client_controller/support/fake_agent_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('first history loading includes the runtime binding stage', () async {
    final controller = _SelectionController();
    addTearDown(controller.dispose);
    final selected = controller.selectConversationAgent('codex');
    expect(controller.isLoadingConversations, isTrue);
    expect(controller.reads, isEmpty);
    controller.bindings['codex']!.complete(true);
    await Future<void>.delayed(Duration.zero);
    expect(controller.reads.keys, ['codex']);
    expect(controller.isLoadingConversations, isTrue);
    controller.reads['codex']!.complete(
      const ConversationSessionPage(sessions: [], hasMore: false),
    );
    await selected;
    expect(controller.isLoadingConversations, isFalse);
    expect(controller.preparingNewConversation, isTrue);
  });

  test('a late binding cannot replace a newer Agent selection', () async {
    final controller = _SelectionController();
    addTearDown(controller.dispose);
    final oldSelection = controller.selectConversationAgent('codex');
    final newSelection = controller.selectConversationAgent('opencode');
    controller.bindings['opencode']!.complete(true);
    await Future<void>.delayed(Duration.zero);
    controller.reads['opencode']!.complete(
      const ConversationSessionPage(sessions: [], hasMore: false),
    );
    await newSelection;
    controller.bindings['codex']!.complete(true);
    await oldSelection;
    expect(controller.selectedConversationAgentId, 'opencode');
    expect(controller.reads.keys, ['opencode']);
    expect(controller.conversationSessionLoadingTargets, isEmpty);
  });
}

class _SelectionController extends ClientController {
  _SelectionController() : super(agentService: FakeAgentService());

  final bindings = <String, Completer<bool>>{};
  final reads = <String, Completer<ConversationSessionPage>>{};

  @override
  Future<bool> agentWorkspaceEnsureConversationRuntimeBinding(String agentId) =>
      (bindings[agentId] = Completer<bool>()).future;

  @override
  Future<ConversationSessionPage> readConversationSessionPage(
    String agentId, {
    String sessionId = '',
    required int offset,
    required int pageSize,
    String messageBefore = '',
    int? messageLimit,
    ConversationSessionProgressCallback? onProgress,
  }) => (reads[agentId] = Completer<ConversationSessionPage>()).future;
}
