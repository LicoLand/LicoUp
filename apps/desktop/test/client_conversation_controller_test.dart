import 'dart:convert';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/application/features/conversations/client_conversation_controller.dart';
import 'package:licoup/src/contracts/agent_command_runner.dart';
import 'package:licoup/src/contracts/client_conversation_models.dart';

void main() {
  test(
    'lists real groups and posts exact structured mention memberships',
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
      expect(post['mentionedMembershipIds'], ['membership:codex']);
      expect(controller.failureCode, isEmpty);
    },
  );

  test('suppresses mentions and can target one Agent membership', () async {
    final runner = _ConversationRunner();
    final controller = ClientConversationController(runner: runner);

    await controller.initialize();
    await controller.selectConversation('conversation:group');

    expect(
      await controller.postMessage('plain group note', suppressMentions: true),
      isTrue,
    );
    expect(
      runner.requests.lastWhere(
        (request) => request['action'] == 'conversation.message.post',
      )['mentionedMembershipIds'],
      isEmpty,
    );

    expect(
      await controller.postMessage(
        'continue the entry slot',
        mentionAgentId: 'codex',
      ),
      isTrue,
    );
    expect(
      runner.requests.lastWhere(
        (request) => request['action'] == 'conversation.message.post',
      )['mentionedMembershipIds'],
      ['membership:codex'],
    );
  });

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
      controller.addListener(() => notifications += 1);

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
}

final class _ConversationRunner implements AgentCommandRunner {
  _ConversationRunner({this.groupArchived = false, this.gate});
  final List<Map<String, dynamic>> requests = [];
  bool groupPinned = true;
  bool groupArchived;
  final Completer<void>? gate;
  final Map<String, String> addedAgents = {};

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
    return {
      'ok': true,
      'result': switch (action) {
        'conversation.list' => _conversationList(request),
        'conversation.create' => _conversation('conversation:created'),
        'conversation.get' => _conversation(
          (request['conversationId'] ?? 'conversation:group').toString(),
          addedAgents: addedAgents,
        ),
        'conversation.events.page' => {
          'events': request['conversationId'] == 'conversation:created'
              ? <Map<String, dynamic>>[]
              : [_event()],
          'nextCursor': null,
          'totalCount': request['conversationId'] == 'conversation:created'
              ? 0
              : 1,
        },
        'conversation.message.post' => {
          'event': _event(),
          'directTurns': <Map<String, dynamic>>[],
        },
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
