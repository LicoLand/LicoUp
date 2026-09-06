import 'dart:convert';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/application/features/conversations/client_conversation_controller.dart';
import 'package:licoup/src/contracts/agent_command_runner.dart';
import 'package:licoup/src/contracts/client_conversation_models.dart';

void main() {
  test(
    'posts one Event and dispatches with conversation and event identity only',
    () async {
      final runner = _ConversationRunner();
      final controller = ClientConversationController(runner: runner);

      await controller.initialize();
      expect(controller.groupConversations.map((item) => item.id), [
        'conversation:group',
      ]);

      await controller.selectConversation('conversation:group');
      expect(
        controller.selectedConversation?.activeAgentMemberships,
        hasLength(2),
      );
      expect(controller.events.single.id, 'event:existing');

      expect(await controller.postMessage('hello @Codex'), isTrue);
      final post = runner.requests.lastWhere(
        (request) => request['action'] == 'conversation.message.post',
      );
      expect(post['conversationId'], 'conversation:group');
      expect(post['authorMembershipId'], 'membership:owner');
      expect(post['content'], 'hello @Codex');
      expect(post.containsKey('mentionedMembershipIds'), isFalse);
      final dispatch = runner.requests.lastWhere(
        (request) => request['action'] == 'conversation.dispatch.after-post',
      );
      expect(dispatch.keys.toSet(), {'action', 'conversationId', 'eventId'});
      expect(dispatch['conversationId'], 'conversation:group');
      expect(dispatch['eventId'], 'event:existing');
      expect(controller.failureCode, isEmpty);
    },
  );

  test(
    'plain text posts without mentions and never resolves them client-side',
    () async {
      final runner = _ConversationRunner();
      final controller = ClientConversationController(runner: runner);

      await controller.initialize();
      await controller.selectConversation('conversation:group');

      expect(await controller.postMessage('plain group note'), isTrue);
      final post = runner.requests.lastWhere(
        (request) => request['action'] == 'conversation.message.post',
      );
      expect(post.containsKey('mentionedMembershipIds'), isFalse);
      expect(post['content'], 'plain group note');
      final dispatch = runner.requests.lastWhere(
        (request) => request['action'] == 'conversation.dispatch.after-post',
      );
      expect(dispatch.keys.toSet(), {'action', 'conversationId', 'eventId'});
    },
  );

  test(
    'creates a group from one person and one Agent in one native action',
    () async {
      final runner = _ConversationRunner();
      final controller = ClientConversationController(runner: runner);

      await controller.createGroup(
        title: 'Review room',
        members: const [
          ClientConversationGroupMemberDraft(
            agentId: 'codex',
            displayName: 'Codex',
          ),
        ],
      );

      final creates = runner.requests
          .where((request) => request['action'] == 'conversation.create')
          .toList(growable: false);
      expect(creates, hasLength(1));
      expect((creates.single['members'] as List), hasLength(1));
      expect(
        runner.requests.where(
          (request) => request['action'] == 'conversation.membership.add',
        ),
        isEmpty,
      );
      expect(controller.selectedConversationId, 'conversation:created');
      expect(controller.groupConversations.single.id, 'conversation:created');
    },
  );

  test(
    'selection binds immediately and reuses the loaded conversation snapshot',
    () async {
      final runner = _ConversationRunner();
      final controller = ClientConversationController(runner: runner);

      await controller.initialize();
      await controller.selectConversation('conversation:group');
      final conversationGets = runner.requests
          .where((request) => request['action'] == 'conversation.get')
          .length;
      final eventPages = runner.requests
          .where((request) => request['action'] == 'conversation.events.page')
          .length;

      controller.clearSelection();
      final cachedSelection = controller.selectConversation(
        'conversation:group',
      );

      expect(controller.selectedConversationId, 'conversation:group');
      expect(controller.selectedConversation?.id, 'conversation:group');
      expect(controller.events.single.id, 'event:existing');
      await cachedSelection;
      expect(
        runner.requests
            .where((request) => request['action'] == 'conversation.get')
            .length,
        conversationGets,
      );
      expect(
        runner.requests
            .where((request) => request['action'] == 'conversation.events.page')
            .length,
        eventPages,
      );
    },
  );

  test(
    'controller lifecycle performs no default-group membership writes',
    () async {
      final runner = _ConversationRunner();
      final controller = ClientConversationController(runner: runner);

      await controller.initialize();
      expect(controller.groupConversations, isNotEmpty);

      expect(
        runner.requests.map((request) => request['action']),
        isNot(contains('conversation.default-local-group.${'sync'}')),
      );
      expect(
        runner.requests.where(
          (request) =>
              (request['action'] as String?)?.startsWith(
                'conversation.membership.',
              ) ??
              false,
        ),
        isEmpty,
      );
      expect(
        runner.requests.where(
          (request) => request['action'] == 'conversation.create',
        ),
        isEmpty,
      );
    },
  );

  test(
    'an explicit roster mention adds a newly discovered Agent once',
    () async {
      final runner = _ConversationRunner();
      final controller = ClientConversationController(runner: runner);

      await controller.initialize();
      await controller.selectConversation('conversation:group');

      expect(
        await controller.ensureSelectedAgentMembership(
          agentId: 'new-agent',
          displayName: 'New Agent',
        ),
        isTrue,
      );
      expect(
        controller.selectedConversation!.activeAgentMemberships.map(
          (membership) => membership.principal.agentId,
        ),
        contains('new-agent'),
      );
      expect(
        runner.requests.where(
          (request) => request['action'] == 'conversation.membership.add',
        ),
        hasLength(1),
      );

      expect(
        await controller.ensureSelectedAgentMembership(
          agentId: 'new-agent',
          displayName: 'New Agent',
        ),
        isTrue,
      );
      expect(
        runner.requests.where(
          (request) => request['action'] == 'conversation.membership.add',
        ),
        hasLength(1),
      );
    },
  );

  test(
    'initialization is single-flight and late disposal stays silent',
    () async {
      final gate = Completer<void>();
      final runner = _ConversationRunner(gate: gate);
      final controller = ClientConversationController(runner: runner);
      var notifications = 0;
      controller.changes.listen((_) => notifications += 1);

      final first = controller.initialize();
      final second = controller.initialize();
      expect(identical(first, second), isTrue);
      controller.dispose();
      final beforeCompletion = notifications;
      gate.complete();
      await Future.wait([first, second]);

      expect(notifications, beforeCompletion);
      expect(
        runner.requests.where(
          (request) => request['action'] == 'conversation.list',
        ),
        hasLength(1),
      );
    },
  );

  test(
    'writes the canonical conversation pin state and refreshes the list',
    () async {
      final runner = _ConversationRunner();
      final controller = ClientConversationController(runner: runner);

      await controller.initialize();
      expect(controller.groupConversations.single.pinned, isTrue);

      await controller.setPinned('conversation:group', false);

      final request = runner.requests.singleWhere(
        (entry) => entry['action'] == 'conversation.pin.set',
      );
      expect(request['conversationId'], 'conversation:group');
      expect(request['pinned'], isFalse);
      expect(controller.groupConversations.single.pinned, isFalse);
      expect(controller.failureCode, isEmpty);
    },
  );

  test(
    'archives the requested canonical conversation without reselection',
    () async {
      final runner = _ConversationRunner();
      final controller = ClientConversationController(runner: runner);

      await controller.initialize();
      expect(
        await controller.archiveConversation('conversation:group'),
        isTrue,
      );

      final request = runner.requests.singleWhere(
        (entry) => entry['action'] == 'conversation.archive',
      );
      expect(request['conversationId'], 'conversation:group');
      expect(request['archived'], isTrue);
      expect(controller.groupConversations, isEmpty);
      expect(controller.failureCode, isEmpty);
    },
  );

  test(
    'lists archived conversations and restores one canonical item',
    () async {
      final runner = _ConversationRunner(groupArchived: true);
      final controller = ClientConversationController(runner: runner);

      await controller.initialize();
      expect(controller.groupConversations, isEmpty);

      expect(await controller.refreshArchived(), isTrue);
      expect(controller.archivedConversations.map((item) => item.id), [
        'conversation:group',
      ]);

      expect(await controller.restoreArchived('conversation:group'), isTrue);
      final restore = runner.requests.singleWhere(
        (request) => request['action'] == 'conversation.archive',
      );
      expect(restore['conversationId'], 'conversation:group');
      expect(restore['archived'], isFalse);
      expect(controller.archivedConversations, isEmpty);
      expect(controller.groupConversations.single.id, 'conversation:group');
      expect(controller.failureCode, isEmpty);
    },
  );

  test('surfaces an explicit group-operation failure on the banner fields', () {
    final controller = ClientConversationController(
      runner: _ConversationRunner(),
    );
    controller.surfaceFailure(
      'strategy/start',
      'strategy_actor_quota_exhausted',
    );
    expect(controller.failureStage, 'strategy/start');
    expect(controller.failureCode, 'strategy_actor_quota_exhausted');
    expect(controller.failureRef, matches(RegExp(r'^#L-[0-9A-F]{4}$')));
    expect(
      controller.failureCopyBlob,
      contains('ref: ${controller.failureRef}'),
    );
    expect(controller.failureCopyBlob, contains('stage: strategy/start'));
    expect(controller.failureProblemCode, 'LU-ST-1923');
    expect(
      controller.failureCopyBlob,
      contains('code: strategy_actor_quota_exhausted'),
    );
    expect(controller.failureCopyBlob, contains('problemCode: LU-ST-1923'));
    expect(controller.failureCopyBlob, contains('domain: strategy'));
  });

  test(
    'keeps the structured resolution for a persisted usage-limit failure',
    () {
      final controller = ClientConversationController(
        runner: _ConversationRunner(),
      );
      controller.surfaceFailure(
        'turn/completed',
        'codex_usage_limit_exceeded',
        component: 'native_cli',
        retryable: false,
        recovery: 'select_available_model_or_wait_for_quota_reset',
      );

      expect(controller.failureProblemCode, 'LU-NA-4239');
      expect(controller.failureComponent, 'native_cli');
      expect(controller.failureRetryable, isFalse);
      expect(
        controller.failureRecovery,
        'select_available_model_or_wait_for_quota_reset',
      );
      expect(controller.failureCopyBlob, contains('component: native_cli'));
      expect(controller.failureCopyBlob, contains('retryable: false'));
      expect(
        controller.failureCopyBlob,
        contains('recovery: select_available_model_or_wait_for_quota_reset'),
      );
      expect(
        controller.failureCopyBlob,
        isNot(contains('runtime fixture detail')),
      );
    },
  );

  test('records a copyable failure ref when post transport fails', () async {
    final runner = _ConversationRunner()..failPostCode = 'transport_failed';
    final controller = ClientConversationController(runner: runner);
    await controller.initialize();
    await controller.selectConversation('conversation:group');

    expect(await controller.postMessage('hi'), isFalse);
    expect(controller.failureStage, 'send');
    expect(controller.failureCode, 'transport_failed');
    expect(controller.failureRef, matches(RegExp(r'^#L-[0-9A-F]{4}$')));
    expect(
      controller.failureCopyBlob,
      contains('ref: ${controller.failureRef}'),
    );
    expect(controller.failureCopyBlob, contains('stage: send'));
    expect(controller.failureCopyBlob, contains('code: transport_failed'));
    expect(controller.failureProblemCode, 'LU-RP-1001');
    expect(controller.failureCopyBlob, contains('problemCode: LU-RP-1001'));
    expect(controller.failureCopyBlob, contains('domain: rpc'));
    expect(controller.failureCopyBlob, isNot(contains('hi')));
  });

  test(
    'captures returned live turns and surfaces a typed strategy error',
    () async {
      final runner = _ConversationRunner()
        ..postTurns = [
          {
            'turnHandle': 'dispatch:live',
            'conversationId': 'conversation:group',
            'agent': 'codex',
          },
        ]
        ..dispatchPending = true;
      final controller = ClientConversationController(runner: runner);
      await controller.initialize();
      await controller.selectConversation('conversation:group');

      expect(await controller.postMessage('hello @Codex'), isTrue);
      expect(controller.liveTurns.single['turnHandle'], 'dispatch:live');
      expect(controller.dispatchPending, isTrue);

      runner
        ..postTurns = const []
        ..dispatchPending = false
        ..failStrategyStart = true;
      expect(await controller.postMessage('start'), isTrue);
      expect(controller.liveTurns, isEmpty);
      expect(controller.dispatchPending, isFalse);
      expect(controller.failureStage, 'strategy/start');
      expect(controller.failureCode, 'strategy_actor_quota_exhausted');
    },
  );

  test(
    'marks a persisted event retryable when after-post dispatch fails',
    () async {
      final runner = _ConversationRunner()
        ..failDispatchCode = 'transport_failed';
      final controller = ClientConversationController(runner: runner);
      await controller.initialize();
      await controller.selectConversation('conversation:group');

      expect(await controller.postMessage('hi'), isTrue);
      final marker = runner.requests.singleWhere(
        (request) => request['action'] == 'conversation.event.append',
      );
      expect(marker['conversationId'], 'conversation:group');
      expect(marker['causationId'], 'event:existing');
      expect(marker['finalized'], isTrue);
      expect(
        jsonDecode(
          ((marker['parts'] as List).single as Map)['content'] as String,
        ),
        {'code': 'transport_failed', 'stage': 'send'},
      );
      expect(
        controller.events.map((event) => event.id),
        containsAll(['event:existing', 'event:failed-turn']),
      );
      expect(controller.failureStage, 'send');
      expect(controller.failureCode, 'transport_failed');
      expect(controller.liveTurns, isEmpty);
      expect(controller.dispatchPending, isFalse);
    },
  );

  test(
    'does not synthesize a code for an untyped dispatch exception',
    () async {
      final runner = _ConversationRunner()..throwUntypedDispatch = true;
      final controller = ClientConversationController(runner: runner);
      await controller.initialize();
      await controller.selectConversation('conversation:group');

      expect(await controller.postMessage('hi'), isTrue);
      expect(controller.failureCode, isEmpty);
      expect(controller.liveTurns, isEmpty);
      expect(controller.dispatchPending, isFalse);
    },
  );

  test('classifies a malformed post result as an invalid response', () async {
    final runner = _ConversationRunner()..malformedPost = true;
    final controller = ClientConversationController(runner: runner);
    await controller.initialize();
    await controller.selectConversation('conversation:group');

    expect(await controller.postMessage('hi'), isFalse);
    expect(controller.failureStage, 'send');
    expect(controller.failureCode, 'invalid_response');
  });

  test(
    'a dispatch without handles and without a typed error records no failure',
    () async {
      final runner = _ConversationRunner()
        ..strategyRevision = 'rev-auth'
        ..dispatchPending = true;
      final controller = ClientConversationController(runner: runner);
      await controller.initialize();
      await controller.selectConversation('conversation:group');

      expect(await controller.postMessage('hi'), isTrue);
      expect(controller.liveTurns, isEmpty);
      expect(controller.dispatchPending, isFalse);
      expect(controller.failureCode, isEmpty);
    },
  );

  test('settleLiveDispatch clears a leftover composer busy latch', () async {
    final runner = _ConversationRunner()
      ..postTurns = [
        {
          'turnHandle': 'dispatch:live',
          'conversationId': 'conversation:group',
          'agent': 'codex',
        },
      ]
      ..dispatchPending = true;
    final controller = ClientConversationController(runner: runner);
    await controller.initialize();
    await controller.selectConversation('conversation:group');
    expect(await controller.postMessage('hello @Codex'), isTrue);
    expect(controller.dispatchPending, isTrue);
    controller.settleLiveDispatch();
    expect(controller.dispatchPending, isFalse);
    expect(controller.liveTurns, isEmpty);
  });

  test(
    'one catalog and timeline refresh runs after dispatch returns',
    () async {
      final runner = _ConversationRunner();
      final controller = ClientConversationController(runner: runner);
      await controller.initialize();
      await controller.selectConversation('conversation:group');
      runner.requests.clear();

      expect(await controller.postMessage('hi'), isTrue);
      final actions = runner.requests
          .map((request) => request['action'])
          .toList();
      expect(actions, [
        'conversation.message.post',
        'conversation.dispatch.after-post',
        'conversation.list',
        'conversation.get',
        'conversation.events.page',
      ]);
    },
  );

  test(
    'failed message retry reposts its content then deletes the settled attempt',
    () async {
      final runner = _ConversationRunner()..includeFailedTurn = true;
      final controller = ClientConversationController(runner: runner);
      await controller.initialize();
      await controller.selectConversation('conversation:group');

      expect(await controller.retryMessage('event:existing'), isTrue);

      final actions = runner.requests
          .map((request) => request['action'])
          .where(
            (action) =>
                action == 'conversation.message.post' ||
                action == 'conversation.dispatch.after-post' ||
                action == 'conversation.message.delete',
          )
          .toList();
      expect(actions, [
        'conversation.message.post',
        'conversation.dispatch.after-post',
        'conversation.message.delete',
      ]);
      final repost = runner.requests.firstWhere(
        (request) => request['action'] == 'conversation.message.post',
      );
      expect(repost['content'], 'hello');
      final deletion = runner.requests.firstWhere(
        (request) => request['action'] == 'conversation.message.delete',
      );
      expect(deletion['eventId'], 'event:existing');
      expect(deletion['ownerMembershipId'], 'membership:owner');
    },
  );

  test('deletes a local message through the canonical store action', () async {
    final runner = _ConversationRunner();
    final controller = ClientConversationController(runner: runner);
    await controller.initialize();
    await controller.selectConversation('conversation:group');

    expect(await controller.deleteMessage('event:existing'), isTrue);

    final deletion = runner.requests.singleWhere(
      (request) => request['action'] == 'conversation.message.delete',
    );
    expect(deletion.keys.toSet(), {
      'action',
      'conversationId',
      'eventId',
      'ownerMembershipId',
    });
  });
}

final class _ConversationRunner implements AgentCommandRunner {
  _ConversationRunner({this.groupArchived = false, this.gate});
  final List<Map<String, dynamic>> requests = [];
  bool groupPinned = true;
  bool groupArchived;
  final Completer<void>? gate;
  final Map<String, String> addedAgents = {};
  bool failStrategyStart = false;
  bool dispatchPending = false;
  bool throwUntypedDispatch = false;
  bool malformedPost = false;
  bool includeFailedTurn = false;
  bool appendedFailure = false;
  bool messageDeleted = false;
  String failPostCode = '';
  String failDispatchCode = '';
  String strategyRevision = '';
  List<Map<String, dynamic>> postTurns = const [];

  @override
  Future<Map<String, dynamic>> runCliWithStdin(
    List<String> args,
    String stdinText,
  ) async {
    await gate?.future;
    expect(args, ['conversation', 'execute', '--stdin-json', 'true']);
    final request = Map<String, dynamic>.from(jsonDecode(stdinText) as Map);
    requests.add(request);
    final action = request['action'];
    if (action == 'conversation.pin.set') {
      groupPinned = request['pinned'] == true;
    }
    if (action == 'conversation.archive') {
      groupArchived = request['archived'] == true;
    }
    if (action == 'conversation.membership.add') {
      final principal = Map<String, dynamic>.from(request['principal'] as Map);
      addedAgents[(principal['agentId'] ?? '').toString()] =
          (principal['displayName'] ?? '').toString();
    }
    if (action == 'conversation.strategy.set') {
      strategyRevision = (request['strategyRevision'] ?? '').toString();
    }
    if (action == 'conversation.message.delete') {
      messageDeleted = true;
    }
    if (action == 'conversation.event.append') {
      appendedFailure = true;
    }
    if (action == 'conversation.message.post' && failPostCode.isNotEmpty) {
      return {
        'ok': false,
        'error': {'code': failPostCode},
      };
    }
    if (action == 'conversation.dispatch.after-post' &&
        failDispatchCode.isNotEmpty) {
      return {
        'ok': false,
        'error': {'code': failDispatchCode},
      };
    }
    if (action == 'conversation.dispatch.after-post' && throwUntypedDispatch) {
      throw StateError('synthetic dispatch exception');
    }
    return {
      'ok': true,
      'result': switch (action) {
        'conversation.list' => _conversationList(request),
        'conversation.create' => _conversation('conversation:created'),
        'conversation.get' => _conversation(
          (request['conversationId'] ?? 'conversation:group').toString(),
          addedAgents: addedAgents,
          strategyRevision: strategyRevision,
        ),
        'conversation.events.page' => {
          'events': request['conversationId'] == 'conversation:created'
              ? <Map<String, dynamic>>[]
              : messageDeleted
              ? <Map<String, dynamic>>[]
              : [
                  _event(),
                  if (includeFailedTurn || appendedFailure) _failedTurnEvent(),
                ],
          'nextCursor': null,
          'totalCount': request['conversationId'] == 'conversation:created'
              ? 0
              : 1,
        },
        'conversation.message.post' =>
          malformedPost
              ? <String, dynamic>{}
              : {
                  'event': _event(),
                  'directTurns': <Map<String, dynamic>>[],
                  'turns': <Map<String, dynamic>>[],
                  'dispatchPending': false,
                },
        'conversation.dispatch.after-post' => {
          'event': {'id': request['eventId']},
          'directTurns': <Map<String, dynamic>>[],
          'turns': postTurns,
          'dispatchPending': dispatchPending && !failStrategyStart,
          if (failStrategyStart)
            'strategyError': <String, dynamic>{
              'code': 'strategy_actor_quota_exhausted',
              'stage': 'strategy/start',
            },
        },
        'conversation.event.append' => _failedTurnEvent(),
        'conversation.message.delete' => <String, dynamic>{},
        'conversation.membership.add' => <String, dynamic>{},
        _ => <String, dynamic>{},
      },
    };
  }

  List<Map<String, dynamic>> _conversationList(
    Map<String, dynamic> request,
  ) => [
    if (!groupArchived || request['includeArchived'] == true)
      _summary(
        id: requests.any((entry) => entry['action'] == 'conversation.create')
            ? 'conversation:created'
            : 'conversation:group',
        members: 3,
        pinned: groupPinned,
        archived: groupArchived,
      ),
    _summary(id: 'conversation:direct', members: 2),
  ];

  @override
  Future<Map<String, dynamic>> runCli(List<String> args) =>
      throw UnimplementedError();

  @override
  Stream<Map<String, dynamic>> streamCliJsonLines(List<String> args) =>
      const Stream.empty();

  @override
  Stream<Map<String, dynamic>> streamCliJsonLinesWithStdin(
    List<String> args,
    String stdinText,
  ) => const Stream.empty();
}

Map<String, dynamic> _summary({
  required String id,
  required int members,
  bool? pinned,
  bool archived = false,
}) => {
  'id': id,
  'title': id == 'conversation:direct' ? 'Direct' : 'Lico',
  'archived': archived,
  'pinned': pinned ?? id == 'conversation:group',
  'isGroup': id != 'conversation:direct',
  'revision': 1,
  'updatedAtUnixMs': 10,
  'membershipCount': members,
  'eventCount': 1,
};

Map<String, dynamic> _conversation(
  String id, {
  Map<String, String> addedAgents = const {},
  String strategyRevision = '',
}) => {
  'id': id,
  'title': id == 'conversation:created' ? 'Review room' : 'Lico',
  'archived': false,
  'pinned': id == 'lico-group-default' || id == 'conversation:group',
  'isGroup': true,
  'revision': 1,
  'createdAtUnixMs': 1,
  'updatedAtUnixMs': 10,
  'eventCount': id == 'conversation:created' ? 0 : 1,
  'strategyRevision': strategyRevision,
  'memberships': [
    _membership(
      id: 'membership:owner',
      principalId: 'human:local',
      kind: 'human',
      label: 'Local User',
      access: 'owner',
    ),
    _membership(
      id: 'membership:codex',
      principalId: 'agent:codex',
      kind: 'agent',
      label: 'Codex',
      agentId: 'codex',
    ),
    _membership(
      id: 'membership:claude',
      principalId: 'agent:claude-code',
      kind: 'agent',
      label: 'Claude Code',
      agentId: 'claude-code',
    ),
    for (final entry in addedAgents.entries)
      _membership(
        id: 'membership:${entry.key}',
        principalId: 'agent:${entry.key}',
        kind: 'agent',
        label: entry.value,
        agentId: entry.key,
      ),
  ],
};

Map<String, dynamic> _membership({
  required String id,
  required String principalId,
  required String kind,
  required String label,
  String agentId = '',
  String access = 'member',
}) => {
  'id': id,
  'conversationId': 'conversation:group',
  'principal': {
    'id': principalId,
    'kind': kind,
    'displayName': label,
    if (agentId.isNotEmpty) 'agentId': agentId,
    'createdAtUnixMs': 1,
  },
  'access': access,
  'status': 'active',
  'joinedAtUnixMs': 1,
};

Map<String, dynamic> _event() => {
  'id': 'event:existing',
  'conversationId': 'conversation:group',
  'sequence': 1,
  'authorMembershipId': 'membership:owner',
  'kind': 'message',
  'createdAtUnixMs': 10,
  'finalized': true,
  'parts': [
    {
      'id': 'part:text',
      'eventId': 'event:existing',
      'ordinal': 0,
      'kind': 'text',
      'content': 'hello',
      'createdAtUnixMs': 10,
    },
  ],
};

Map<String, dynamic> _failedTurnEvent() => {
  'id': 'event:failed-turn',
  'conversationId': 'conversation:group',
  'sequence': 2,
  'authorMembershipId': 'membership:codex',
  'kind': 'message',
  'causationId': 'event:existing',
  'correlationId': 'turn:failed',
  'createdAtUnixMs': 11,
  'finalized': true,
  'parts': [
    {
      'id': 'part:diagnostic',
      'eventId': 'event:failed-turn',
      'ordinal': 0,
      'kind': 'diagnostic',
      'content': '{"code":"fixture_turn_failed"}',
      'createdAtUnixMs': 11,
    },
  ],
};
