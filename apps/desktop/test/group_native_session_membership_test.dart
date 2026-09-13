import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/application/features/agents/conversation/conversation_session_state_controller.dart';
import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/client_conversation_models.dart';

void main() {
  test(
    'group maps only exact bound reads without consuming or updating Agent browse',
    () async {
      final controller = _HistoryController();
      addTearDown(controller.dispose);
      final browse = [
        for (var i = 0; i < 1000; i++) _session('unrelated-$i', end: 0),
        _session('bound', title: 'Stale browse title'),
      ];
      controller.conversationSessionsByAgent = {'codex': browse};
      final pending = controller.hydrateGroupConversationSessions(
        _group('group', ['bound', 'historic']),
      );
      expect(controller.reads.map((read) => read.id), ['bound', 'historic']);
      controller.reads[0].complete(_session('bound', title: 'Exact title'));
      controller.reads[1].complete(_session('historic'));
      await pending;
      expect(
        controller.groupNativeSessions.sessionsByAgent['codex']!.map(
          (s) => s.title,
        ),
        contains('Exact title'),
      );
      expect(
        controller.groupNativeSessions.sessionsByAgent['codex'],
        hasLength(2),
      );
      expect(controller.conversationSessionsByAgent['codex'], same(browse));
      await controller.loadConversationSessions('codex');
      await controller.loadMoreConversationSessions('codex');
      await controller.refreshConversationCatalogInternal(
        'codex',
        foreground: false,
      );
      expect(controller.reads, hasLength(2));
      controller.conversationSessionsByAgent = {};
      expect(
        controller.groupNativeSessions.sessionsByAgent['codex'],
        hasLength(2),
      );
    },
  );

  test(
    'each completed exact read publishes and starts the next before slower workers finish',
    () async {
      final controller = _HistoryController();
      addTearDown(controller.dispose);
      final pending = controller.hydrateGroupConversationSessions(
        _group('group', ['slow', 'two', 'three', 'four', 'five']),
      );
      final joined = controller.hydrateGroupConversationSessions(
        _group('group', ['slow', 'two', 'three', 'four', 'five']),
      );
      expect(controller.reads, hasLength(4));
      controller.reads[3].complete(_session('four'));
      await Future<void>.delayed(Duration.zero);
      expect(
        controller
            .groupNativeSessions
            .sessionsByAgent['codex']!
            .single
            .nativeSessionId,
        'four',
      );
      expect(controller.reads, hasLength(5));
      expect(controller.reads[4].id, 'five');
      for (final index in [0, 1, 2, 4]) {
        controller.reads[index].complete(_session(controller.reads[index].id));
      }
      await Future.wait([pending, joined]);
      expect(
        controller.groupNativeSessions.sessionsByAgent['codex'],
        hasLength(5),
      );
      expect(controller.groupNativeSessions.loading, isFalse);
    },
  );

  test(
    'switching groups drops late results including a shared native identity',
    () async {
      final controller = _HistoryController();
      addTearDown(controller.dispose);
      final first = controller.hydrateGroupConversationSessions(
        _group('first', ['shared']),
      );
      controller.selectGroupConversationHistory('second');
      expect(controller.groupNativeSessions.sessionsByAgent, isEmpty);
      final second = controller.hydrateGroupConversationSessions(
        _group('second', ['shared']),
      );
      controller.reads[0].complete(
        _session('shared', title: 'Stale first response'),
      );
      await first;
      expect(controller.groupNativeSessions.sessionsByAgent, isEmpty);
      controller.reads[1].complete(
        _session('shared', title: 'Current second response'),
      );
      await second;
      expect(
        controller.groupNativeSessions.sessionsByAgent['codex']!.single.title,
        'Current second response',
      );
      expect(controller.conversationSessionsByAgent, isEmpty);
    },
  );

  test(
    'same-group relationship changes invalidate pending responses and remove obsolete bindings',
    () async {
      final controller = _HistoryController();
      addTearDown(controller.dispose);
      final first = controller.hydrateGroupConversationSessions(
        _group('group', ['old', 'retained']),
      );
      final changed = controller.hydrateGroupConversationSessions(
        _group('group', ['retained', 'new']),
      );
      controller.reads[0].complete(_session('old'));
      controller.reads[1].complete(_session('retained', title: 'Stale'));
      await first;
      expect(controller.groupNativeSessions.sessionsByAgent, isEmpty);
      controller.reads[2].complete(_session('retained', title: 'Current'));
      controller.reads[3].complete(_session('new'));
      await changed;
      expect(
        controller.groupNativeSessions.sessionsByAgent['codex']!.map(
          (s) => s.nativeSessionId,
        ),
        unorderedEquals(['retained', 'new']),
      );
      await controller.hydrateGroupConversationSessions(_group('group', []));
      expect(controller.groupNativeSessions.sessionsByAgent, isEmpty);
    },
  );

  test(
    'missing metadata stays absent and refresh reads only recorded identities',
    () async {
      final controller = _HistoryController();
      addTearDown(controller.dispose);
      final initial = controller.hydrateGroupConversationSessions(
        _group('group', ['bound', 'unreadable']),
      );
      controller.reads[0].complete(_session('bound'));
      controller.reads[1].complete(null);
      await initial;
      expect(
        controller.groupNativeSessions.sessionsByAgent['codex'],
        hasLength(1),
      );
      expect(controller.groupNativeSessions.identities, hasLength(2));
      expect(
        controller.groupNativeSessions.failedIdentities.single.nativeSessionId,
        'unreadable',
      );
      final refresh = controller.refreshGroupConversationSessions();
      expect(controller.reads.skip(2).map((read) => read.id), [
        'bound',
        'unreadable',
      ]);
      controller.reads[2].complete(_session('bound', title: 'Refreshed'));
      controller.reads[3].complete(null);
      await refresh;
      expect(
        controller.groupNativeSessions.sessionsByAgent['codex']!.single.title,
        'Refreshed',
      );
      expect(controller.conversationSessionsByAgent, isEmpty);
    },
  );

  test(
    'group selection and latest/earlier message pages use the dedicated subset',
    () async {
      final controller = _HistoryController();
      addTearDown(controller.dispose);
      final browse = [_session('unrelated')];
      controller.conversationSessionsByAgent = {'codex': browse};
      final hydration = controller.hydrateGroupConversationSessions(
        _group('group', ['bound']),
      );
      controller.reads[0].complete(_session('bound', start: 40));
      await hydration;
      controller.selectGroupConversationSession(
        'group',
        'codex',
        'catalog:codex:bound',
      );
      expect(controller.selectedConversationSession!.nativeSessionId, 'bound');
      expect(controller.reads[1].id, 'bound');
      expect(controller.reads[1].before, '');
      controller.reads[1].complete(_session('bound', start: 40));
      await Future<void>.delayed(Duration.zero);
      final older = controller.loadEarlierConversationMessages();
      expect(controller.reads[2].id, 'bound');
      expect(controller.reads[2].before, '40');
      controller.reads[2].complete(_session('bound', start: 20, end: 40));
      await older;
      expect(controller.selectedConversationSession!.messages, hasLength(40));
      expect(controller.selectedConversationSession!.messagePage.start, 20);
      expect(controller.conversationSessionsByAgent['codex'], same(browse));
      controller.selectGroupConversationSession('group', 'codex', 'unrelated');
      expect(controller.selectedConversationSession!.nativeSessionId, 'bound');
      expect(controller.reads, hasLength(3));
      expect(controller.selectedConversationSessionsHasMore, isFalse);
    },
  );

  test(
    'old message page cannot enter another group with the same selected native session',
    () async {
      final controller = _HistoryController();
      addTearDown(controller.dispose);
      final first = controller.hydrateGroupConversationSessions(
        _group('first', ['shared']),
      );
      controller.reads[0].complete(_session('shared'));
      await first;
      controller.selectGroupConversationSession('first', 'codex', 'shared');
      final second = controller.hydrateGroupConversationSessions(
        _group('second', ['shared']),
      );
      controller.reads[2].complete(_session('shared', title: 'Second'));
      await second;
      controller.selectGroupConversationSession('second', 'codex', 'shared');
      expect(controller.reads, hasLength(4));
      controller.reads[1].complete(
        _session('shared', title: 'Late first page'),
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.selectedConversationSession!.title, 'Second');
      controller.reads[3].complete(_session('shared', title: 'Second latest'));
      await Future<void>.delayed(Duration.zero);
      expect(controller.selectedConversationSession!.title, 'Second latest');
      expect(controller.conversationSessionsByAgent, isEmpty);
    },
  );

  test(
    'removing the selected binding clears its message view while old pages finish',
    () async {
      final controller = _HistoryController();
      addTearDown(controller.dispose);
      final hydration = controller.hydrateGroupConversationSessions(
        _group('group', ['selected', 'remaining']),
      );
      controller.reads[0].complete(_session('selected'));
      controller.reads[1].complete(_session('remaining'));
      await hydration;
      controller.selectGroupConversationSession('group', 'codex', 'selected');
      expect(controller.selectedConversationSession, isNotNull);
      await controller.hydrateGroupConversationSessions(
        _group('group', ['remaining']),
      );
      expect(controller.selectedConversationSessionId, isEmpty);
      expect(controller.selectedConversationSession, isNull);
      controller.reads[2].complete(
        _session('selected', title: 'Late removed page'),
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.selectedConversationSession, isNull);
      expect(
        controller
            .groupNativeSessions
            .sessionsByAgent['codex']!
            .single
            .nativeSessionId,
        'remaining',
      );
    },
  );

  test(
    'empty bindings and leaving the group settle loading and discard errors from old reads',
    () async {
      final controller = _HistoryController();
      addTearDown(controller.dispose);
      final old = controller.hydrateGroupConversationSessions(
        _group('group', ['old']),
      );
      expect(controller.groupNativeSessions.loading, isTrue);
      await controller.hydrateGroupConversationSessions(_group('group', []));
      expect(controller.groupNativeSessions.loading, isFalse);
      controller.reads[0].result.completeError(
        const FormatException('synthetic old read'),
      );
      await old;
      expect(controller.groupNativeSessions.failedIdentities, isEmpty);
      final next = controller.hydrateGroupConversationSessions(
        _group('group', ['next']),
      );
      controller.selectGroupConversationHistory('');
      controller.reads[1].result.completeError(
        const FormatException('synthetic next read'),
      );
      await next;
      expect(controller.groupNativeSessions.conversationId, isEmpty);
      expect(controller.groupNativeSessions.identities, isEmpty);
      expect(controller.groupNativeSessions.sessionsByAgent, isEmpty);
      expect(controller.groupNativeSessions.failedIdentities, isEmpty);
      expect(controller.groupNativeSessions.loading, isFalse);
    },
  );

  test(
    'group refresh and execution readback retain accumulated pages without writing Agent browse',
    () async {
      final controller = _HistoryController();
      addTearDown(controller.dispose);
      final browse = [_session('unrelated', end: 0)];
      controller.conversationSessionsByAgent = {'codex': browse};
      final hydration = controller.hydrateGroupConversationSessions(
        _group('group', ['bound']),
      );
      controller.reads[0].complete(_session('bound', start: 20));
      await hydration;
      controller.selectedConversationAgentId = 'codex';
      controller.selectedConversationSessionId = 'catalog:codex:bound';
      final refresh = controller.refreshGroupConversationSessions();
      controller.reads[1].complete(_session('bound', start: 40));
      await refresh;
      expect(controller.selectedConversationSession!.messagePage.start, 20);
      expect(controller.selectedConversationSession!.messages, hasLength(40));
      expect(
        await controller.conversationCommitTurnBoundNativeReadback(
          agentId: 'codex',
          nativeSessionId: 'bound',
          mergeWithSelectedSession: true,
          messages: const [
            AgentConversationMessage(
              id: 'bound:60',
              stableIdentity: 'bound:60',
              role: 'assistant',
              text: 'Synthetic completed turn',
              createdAt: '2026-09-13T00:00:01Z',
            ),
          ],
        ),
        isTrue,
      );
      expect(controller.selectedConversationSession!.messages, hasLength(41));
      expect(controller.selectedConversationSession!.messagePage.start, 20);
      expect(
        controller.selectedConversationSession!.messagePage.nextBefore,
        'bound:20',
      );
      expect(
        controller.selectedConversationSession!.messagePage.hasEarlier,
        isTrue,
      );
      expect(
        controller.groupNativeSessions.sessionsByAgent['codex'],
        hasLength(1),
      );
      expect(controller.conversationSessionsByAgent['codex'], same(browse));
      expect(
        await controller.conversationCommitTurnBoundNativeReadback(
          agentId: 'codex',
          nativeSessionId: 'unbound',
          mergeWithSelectedSession: false,
          messages: const [],
        ),
        isFalse,
      );
      expect(controller.groupNativeSessions.identities, hasLength(1));
      expect(
        controller.groupNativeSessions.sessionsByAgent['codex'],
        hasLength(1),
      );
      expect(controller.conversationSessionsByAgent['codex'], same(browse));
    },
  );

  test(
    'local get reference facts decode without inventing missing membership',
    () {
      final conversation = ClientConversation.fromJson({
        'id': 'group',
        'isGroup': true,
        'nativeSessionReferences': [
          {
            'membershipId': 'left-member',
            'agentId': 'codex',
            'nativeSessionId': 'old',
          },
        ],
      });
      expect(
        conversation.nativeSessionReferences.single.membershipId,
        'left-member',
      );
      expect(
        conversation.nativeSessionReferences.single.nativeSessionId,
        'old',
      );
      expect(
        ClientConversation.fromJson({'id': 'group'}).nativeSessionReferences,
        isEmpty,
      );
    },
  );
}

ClientConversation _group(String id, List<String> ids) => ClientConversation(
  id: id,
  title: id,
  archived: false,
  group: true,
  revision: 1,
  createdAtUnixMs: 1,
  updatedAtUnixMs: 1,
  memberships: const [],
  eventCount: 0,
  nativeSessionReferences: [
    for (final session in ids)
      ClientConversationNativeSessionReference(
        membershipId: 'left-member:$id',
        agentId: 'codex',
        nativeSessionId: session,
      ),
  ],
);

AgentConversationSession _session(
  String id, {
  String? title,
  int start = 0,
  int end = 60,
}) => AgentConversationSession(
  id: 'catalog:codex:$id',
  agentId: 'codex',
  title: title ?? 'Synthetic $id',
  createdAt: '2026-09-13T00:00:00Z',
  updatedAt: '2026-09-13T00:00:00Z',
  nativeSessionId: id,
  messages: [
    for (var i = start; i < end; i++)
      AgentConversationMessage(
        id: '$id:$i',
        stableIdentity: '$id:$i',
        role: 'assistant',
        text: 'Synthetic $i',
        createdAt: '2026-09-13T00:00:00Z',
      ),
  ],
  messagePage: AgentConversationMessagePage(
    start: start,
    endExclusive: end,
    returned: end - start,
    total: 60,
    hasEarlier: start > 0,
    nextBefore: start > 0 ? '$start' : '',
  ),
);

class _Read {
  _Read(this.id, this.before);
  final String id;
  final String before;
  final result = Completer<ConversationSessionPage>();
  void complete(AgentConversationSession? session) => result.complete(
    ConversationSessionPage(sessions: [?session], hasMore: false),
  );
}

class _HistoryController extends ClientController {
  final reads = <_Read>[];
  @override
  void conversationAttentionContextChanged({bool immediateActive = true}) {}
  @override
  void agentWorkspaceRecordCurrentAgentView() {}
  @override
  void ensureConversationInterfaceModelCatalog([String? agentId]) {}
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
    expect(agentId, 'codex');
    expect(
      sessionId,
      isNotEmpty,
      reason: 'A group never opens an Agent-wide history read.',
    );
    expect(pageSize, 1);
    expect(messageLimit, 20);
    final read = _Read(sessionId, messageBefore);
    reads.add(read);
    return read.result.future;
  }
}
