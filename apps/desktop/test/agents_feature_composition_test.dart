import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/composition/features/agents/agents_feature_composition.dart';
import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/client_memory_diagnostics.dart';
import 'package:licoup/src/contracts/conversation_native_port.dart';
import 'package:licoup/src/platform/native_client/agent_service.dart';
import 'package:licoup/src/presentation/agents/agents_intent.dart';

void main() {
  test('OpenAgentConversation selects the newest parent session', () async {
    final controller = _Controller()..seedCatalog('codex');
    addTearDown(controller.dispose);
    final composition = AgentsFeatureComposition(controller);
    addTearDown(composition.close);

    composition.binding.intents.send(const OpenAgentConversation('codex'));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(controller.calls, [
      'selectAgent:codex',
      'selectSession:session-recent',
    ]);
  });

  test('OpenAgentConversation ignores newer sub-agent threads', () async {
    final controller = _Controller()
      ..seedCatalog('codex', childPreview: 'newer child thread');
    addTearDown(controller.dispose);
    final composition = AgentsFeatureComposition(controller);
    addTearDown(composition.close);

    composition.binding.intents.send(const OpenAgentConversation('codex'));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(controller.calls, contains('selectSession:session-recent'));
    expect(controller.calls, isNot(contains('selectSession:session-child')));
  });

  test(
    'OpenAgentConversation loads a missing catalog before choosing',
    () async {
      final controller = _Controller()..catalogOnLoad = true;
      addTearDown(controller.dispose);
      final composition = AgentsFeatureComposition(controller);
      addTearDown(composition.close);

      composition.binding.intents.send(const OpenAgentConversation('codex'));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final loadIndex = controller.calls.indexOf('load:codex');
      final selectIndex = controller.calls.indexOf(
        'selectSession:session-recent',
      );
      expect(loadIndex, isNonNegative);
      expect(selectIndex, isNonNegative);
      expect(loadIndex, lessThan(selectIndex));
    },
  );

  test(
    'OpenAgentConversation starts a new conversation without sessions',
    () async {
      final controller = _Controller()..seedCatalog('codex', empty: true);
      addTearDown(controller.dispose);
      final composition = AgentsFeatureComposition(controller);
      addTearDown(composition.close);

      composition.binding.intents.send(const OpenAgentConversation('codex'));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(controller.calls, ['selectAgent:codex', 'new']);
    },
  );
}

AgentConversationSession _session(
  String id,
  String agentId, {
  required Duration updatedAgo,
  String parentSessionId = '',
}) {
  final stamp = DateTime.now().subtract(updatedAgo).toUtc().toIso8601String();
  return AgentConversationSession(
    id: id,
    agentId: agentId,
    title: id,
    createdAt: stamp,
    updatedAt: stamp,
    messages: const [],
    parentSessionId: parentSessionId,
  );
}

final class _Controller extends ClientController {
  _Controller()
    : super(
        agentService: _Service(),
        conversationNativePort: _Native(),
        memoryDiagnosticSink: const NoopClientMemoryDiagnosticSink(),
      );

  final calls = <String>[];
  bool catalogOnLoad = false;

  void seedCatalog(
    String agentId, {
    bool empty = false,
    String childPreview = '',
  }) {
    conversationSessionsByAgent = {
      ...conversationSessionsByAgent,
      agentId: empty
          ? const <AgentConversationSession>[]
          : [
              _session(
                'session-old',
                agentId,
                updatedAgo: const Duration(days: 2),
              ),
              _session(
                'session-recent',
                agentId,
                updatedAgo: const Duration(hours: 1),
              ),
              _session(
                'session-child',
                agentId,
                updatedAgo: Duration.zero,
                parentSessionId: 'session-old',
              ),
            ],
    };
  }

  @override
  Future<void> selectConversationAgent(String agentId) async {
    calls.add('selectAgent:$agentId');
    selectedConversationAgentId = agentId;
  }

  @override
  Future<void> loadConversationSessions(String agentId) async {
    calls.add('load:$agentId');
    if (catalogOnLoad) {
      seedCatalog(agentId);
    }
  }

  @override
  void selectConversationSession(String sessionId) {
    calls.add('selectSession:$sessionId');
    selectedConversationSessionId = sessionId;
  }

  @override
  void startNewConversationSession() {
    calls.add('new');
  }
}

final class _Service extends AgentService {
  @override
  Future<Map<String, dynamic>> runCli(List<String> args) async => {
    'ok': true,
    'sessions': <Object>[],
    'turns': <Object>[],
  };

  @override
  Future<Map<String, dynamic>> runCliWithStdin(
    List<String> args,
    String stdinText,
  ) => runCli(args);
}

final class _Native implements ClientConversationNativePort {
  @override
  Future<Map<String, dynamic>> executeClientConversation(
    ClientConversationCommand command,
  ) async => {
    'ok': true,
    'result': switch (command.payload['action']) {
      'conversation.list' => <Object>[],
      _ => <String, dynamic>{},
    },
  };
}
