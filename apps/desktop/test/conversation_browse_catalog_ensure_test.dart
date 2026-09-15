import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/application/features/agents/conversation/conversation_session_state_controller.dart';
import 'package:licoup/src/composition/features/conversation/conversation_feature_composition.dart';
import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/presentation/conversation/conversation_intent.dart';
import 'package:licoup/src/projections/conversation/conversation_projection_producer.dart';

import 'fixtures/client_controller/support/fake_agent_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'browse catalog warm loads recent 1:1 sessions while a group is selected',
    () async {
      final controller = _BrowseController();
      addTearDown(controller.dispose);
      controller.selectGroupConversationHistory('group');
      final pending = controller.ensureAgentBrowseCatalog('codex');
      expect(controller.reads, hasLength(1));
      expect(controller.reads.single.sessionId, isEmpty);
      expect(
        controller.reads.single.pageSize,
        conversationRecentCatalogPageSize,
      );
      controller.pages['codex']!.complete(
        ConversationSessionPage(
          sessions: [
            _session('codex', 'recent-one'),
            _session('codex', 'recent-two'),
          ],
          hasMore: true,
        ),
      );
      await pending;
      expect(
        controller.conversationSessionsByAgent['codex']!.map(
          (session) => session.id,
        ),
        ['recent-one', 'recent-two'],
      );
      expect(controller.conversationSessionsHasMoreByAgent['codex'], isTrue);
      expect(controller.groupNativeSessions.conversationId, 'group');
      expect(controller.groupNativeSessions.sessionsByAgent, isEmpty);
      expect(controller.selectedConversationSessionId, isEmpty);

      await controller.ensureAgentBrowseCatalog('codex');
      expect(controller.reads, hasLength(1));
    },
  );

  test(
    'empty browse catalogs stay cached so later returns do not reload',
    () async {
      final controller = _BrowseController();
      addTearDown(controller.dispose);
      final pending = controller.ensureAgentBrowseCatalog('codex');
      controller.pages['codex']!.complete(
        const ConversationSessionPage(sessions: [], hasMore: false),
      );
      await pending;
      expect(
        controller.conversationSessionsByAgent.containsKey('codex'),
        isTrue,
      );
      expect(controller.conversationSessionsByAgent['codex'], isEmpty);
      await controller.ensureAgentBrowseCatalog('codex');
      expect(controller.reads, hasLength(1));
    },
  );

  test('all conversation agents warm concurrently', () async {
    final controller = _BrowseController()
      ..scannedTargets = [
        _agent('codex', 'Codex'),
        _agent('claude-code', 'Claude Code'),
        _agent('code', 'VS Code'),
      ];
    addTearDown(controller.dispose);
    final pending = controller.ensureConversationAgentBrowseCatalogs();
    expect(
      controller.reads.map((read) => read.agentId),
      unorderedEquals(['codex', 'claude-code']),
    );
    expect(
      controller.reads.map((read) => read.pageSize),
      everyElement(conversationRecentCatalogPageSize),
    );
    controller.pages['codex']!.complete(
      ConversationSessionPage(
        sessions: [_session('codex', 'codex-recent')],
        hasMore: false,
      ),
    );
    controller.pages['claude-code']!.complete(
      ConversationSessionPage(
        sessions: [_session('claude-code', 'claude-recent')],
        hasMore: false,
      ),
    );
    await pending;
    expect(controller.conversationSessionsByAgent['codex'], hasLength(1));
    expect(controller.conversationSessionsByAgent['claude-code'], hasLength(1));
  });

  test(
    'native projection keeps 1:1 browse catalogs while a group is selected',
    () {
      final controller = _BrowseController()
        ..conversationSessionsByAgent = {
          'codex': [_session('codex', 'recent')],
        };
      addTearDown(controller.dispose);
      controller.selectGroupConversationHistory('group');
      final producer = ConversationProjectionProducer(controller);
      addTearDown(producer.close);
      expect(producer.nativeCatalog.current.groupConversationId, 'group');
      expect(
        producer.nativeCatalog.current.agentCatalogs.single.agentId,
        'codex',
      );
      expect(
        producer.nativeCatalog.current.agentCatalogs.single.sessions.single.id,
        'recent',
      );
    },
  );

  test(
    'catalog prefetch intent warms browse history while a group is selected',
    () async {
      final controller = _BrowseController();
      final composition = ConversationFeatureComposition(controller);
      addTearDown(() async {
        await composition.close();
        controller.dispose();
      });
      controller.selectGroupConversationHistory('group');
      composition.binding.intents.send(
        const RefreshConversationCatalog(agentId: 'codex'),
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.reads, hasLength(1));
      expect(controller.reads.single.sessionId, isEmpty);
      expect(
        controller.reads.single.pageSize,
        conversationRecentCatalogPageSize,
      );
      controller.pages['codex']!.complete(
        ConversationSessionPage(
          sessions: [_session('codex', 'prefetched')],
          hasMore: false,
        ),
      );
      await _settleUntil(
        () => controller.conversationSessionsByAgent.containsKey('codex'),
      );
      expect(controller.conversationSessionsByAgent['codex'], hasLength(1));
      composition.binding.intents.send(
        const RefreshConversationCatalog(agentId: 'codex'),
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.reads, hasLength(1));
    },
  );
}

Future<void> _settleUntil(bool Function() condition) async {
  for (var attempt = 0; attempt < 80; attempt += 1) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('browse catalog did not land');
}

TargetCandidate _agent(String id, String label) => TargetCandidate(
  id: id,
  target: id,
  label: label,
  kind: 'cli',
  status: 'detected',
  configured: true,
  confidence: 1,
  adapterStatus: 'implemented',
);

AgentConversationSession _session(String agentId, String id) =>
    AgentConversationSession(
      id: id,
      agentId: agentId,
      title: 'Synthetic $id',
      createdAt: '2026-09-13T00:00:00Z',
      updatedAt: '2026-09-13T00:00:00Z',
      messages: const [],
    );

class _BrowseController extends ClientController {
  _BrowseController() : super(agentService: FakeAgentService());

  final reads = <({String agentId, String sessionId, int pageSize})>[];
  final pages = <String, Completer<ConversationSessionPage>>{};

  @override
  Future<ConversationSessionPage> readConversationSessionPage(
    String agentId, {
    String sessionId = '',
    required int offset,
    required int pageSize,
    String messageBefore = '',
    int? messageLimit,
    ConversationSessionProgressCallback? onProgress,
  }) {
    reads.add((agentId: agentId, sessionId: sessionId, pageSize: pageSize));
    return (pages[agentId] ??= Completer<ConversationSessionPage>()).future;
  }
}
