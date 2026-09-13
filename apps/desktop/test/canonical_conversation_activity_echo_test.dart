import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/application/features/conversations/client_conversation_controller.dart';
import 'package:licoup/src/contracts/conversation_native_port.dart';

/// Work reaches a Canonical Conversation from actors this client never asked:
/// an external dispatch, a peer client, a subagent, or a settling Flywheel
/// step. Every reload path is otherwise user-driven, so those events used to
/// stay invisible until the next interaction — the conversation looked stalled
/// while an Agent was in fact working inside it.
void main() {
  test(
    'an append made by another actor reaches the selected surface',
    () async {
      final runner = _ActivityRunner();
      final controller = ClientConversationController(
        native: runner,
        pendingNoticePollInterval: const Duration(hours: 1),
        activityEchoInterval: const Duration(hours: 1),
      );
      addTearDown(controller.dispose);

      await controller.initialize();
      await controller.selectConversation('lico-group-default');
      expect(controller.events.map((event) => event.sequence), [1]);

      // Another actor appends while this client is idle.
      runner.appendExternalReply();

      await controller.pollSelectedConversationActivity();

      expect(controller.events.map((event) => event.sequence), [1, 2]);
      expect(
        controller.events.last.parts.single.content,
        'done: codex replied',
      );
      expect(controller.selectedConversation?.revision, 2);
      // The poll already holds the fresh record, so it must not read the same
      // conversation a second time while reconciling.
      expect(runner.conversationReads, 2);
    },
  );

  test(
    'a failing reconcile stays contained instead of escaping the timer',
    () async {
      final runner = _ActivityRunner();
      final controller = ClientConversationController(
        native: runner,
        pendingNoticePollInterval: const Duration(hours: 1),
        activityEchoInterval: const Duration(hours: 1),
      );
      addTearDown(controller.dispose);

      await controller.initialize();
      await controller.selectConversation('lico-group-default');
      final before = controller.events.map((event) => event.sequence).toList();

      // A peer appended, then the service began refusing reads. A user-driven
      // operation would surface a banner; a background reconcile must instead
      // stay silent and let the next tick retry.
      runner.appendExternalReply();
      runner.failConversationReads = true;

      await controller.pollSelectedConversationActivity();

      expect(controller.events.map((event) => event.sequence).toList(), before);
      expect(controller.failureCode, isEmpty);
    },
  );

  test('an unchanged conversation is not reloaded', () async {
    final runner = _ActivityRunner();
    final controller = ClientConversationController(
      native: runner,
      pendingNoticePollInterval: const Duration(hours: 1),
      activityEchoInterval: const Duration(hours: 1),
    );
    addTearDown(controller.dispose);

    await controller.initialize();
    await controller.selectConversation('lico-group-default');
    runner.eventPageReads = 0;

    await controller.pollSelectedConversationActivity();
    await controller.pollSelectedConversationActivity();

    // The cheap revision read runs every tick; the transcript read only runs
    // for a real append.
    expect(runner.conversationReads, greaterThan(0));
    expect(runner.eventPageReads, 0);
  });

  test('no selected conversation leaves the poll inert', () async {
    final runner = _ActivityRunner();
    final controller = ClientConversationController(
      native: runner,
      pendingNoticePollInterval: const Duration(hours: 1),
      activityEchoInterval: const Duration(hours: 1),
    );
    addTearDown(controller.dispose);

    await controller.initialize();
    runner.conversationReads = 0;

    await controller.pollSelectedConversationActivity();

    expect(runner.conversationReads, 0);
  });

  /// The notice poll owns a narrow contract: it may ask for pending notices and
  /// nothing else, so it never disturbs the selected transcript. The echo reads
  /// the conversation, so it must not share that timer.
  test('the notice poll does not read the conversation', () async {
    final runner = _ActivityRunner();
    final controller = ClientConversationController(
      native: runner,
      pendingNoticePollInterval: const Duration(hours: 1),
      activityEchoInterval: const Duration(hours: 1),
    );
    addTearDown(controller.dispose);

    await controller.initialize();
    await controller.selectConversation('lico-group-default');
    runner.conversationReads = 0;
    runner.eventPageReads = 0;
    runner.appendExternalReply();

    await controller.pollPendingCompletionNotices();

    expect(runner.conversationReads, 0);
    expect(runner.eventPageReads, 0);
    expect(
      runner.requests.where(
        (request) => request['action'] == 'list-pending-completion-notices',
      ),
      isNotEmpty,
    );
  });
}

final class _ActivityRunner implements ClientConversationNativePort {
  final List<Map<String, dynamic>> requests = <Map<String, dynamic>>[];
  int eventPageReads = 0;
  int conversationReads = 0;
  bool failConversationReads = false;
  int _revision = 1;
  int _eventCount = 1;

  void appendExternalReply() {
    _revision = 2;
    _eventCount = 2;
  }

  @override
  Future<Map<String, dynamic>> executeClientConversation(
    ClientConversationCommand command,
  ) async {
    final request = command.payload;
    requests.add(request);
    return switch (request['action']) {
      'conversation.list' => _ok(
        request['includeArchived'] == true
            ? const <Map<String, dynamic>>[]
            : [_summary()],
      ),
      'conversation.get' => () {
        conversationReads += 1;
        if (failConversationReads) {
          return <String, dynamic>{
            'ok': false,
            'error': {'code': 'conversation_state_unavailable'},
          };
        }
        return _ok(_conversation());
      }(),
      'conversation.events.page' => () {
        eventPageReads += 1;
        return _ok(<String, dynamic>{
          'events': _events(),
          'nextCursor': null,
          'totalCount': _eventCount,
        });
      }(),
      'list-pending-completion-notices' => _ok(<String, dynamic>{
        'pendingCompletionNotices': const <Map<String, dynamic>>[],
      }),
      _ => _ok(const <String, dynamic>{}),
    };
  }

  Map<String, dynamic> _ok(Object? result) => <String, dynamic>{
    'ok': true,
    'result': ?result,
  };

  Map<String, dynamic> _summary() => <String, dynamic>{
    'id': 'lico-group-default',
    'title': 'Local',
    'archived': false,
    'isGroup': true,
    'revision': _revision,
    'updatedAtUnixMs': 1000,
    'membershipCount': 2,
    'eventCount': _eventCount,
  };

  Map<String, dynamic> _conversation() => <String, dynamic>{
    'id': 'lico-group-default',
    'title': 'Local',
    'archived': false,
    'isGroup': true,
    'assistantMembershipId': 'membership:assistant',
    'revision': _revision,
    'createdAtUnixMs': 1,
    'updatedAtUnixMs': 1000,
    'eventCount': _eventCount,
    'memberships': const [
      {
        'id': 'membership:human',
        'conversationId': 'lico-group-default',
        'status': 'active',
        'access': 'owner',
        'principal': {
          'id': 'principal:human',
          'kind': 'human',
          'displayName': 'Local',
          'agentId': '',
          'createdAtUnixMs': 1,
        },
      },
      {
        'id': 'membership:assistant',
        'conversationId': 'lico-group-default',
        'status': 'active',
        'access': 'member',
        'principal': {
          'id': 'principal:codex',
          'kind': 'agent',
          'displayName': 'Codex CLI',
          'agentId': 'codex',
          'createdAtUnixMs': 1,
        },
      },
    ],
  };

  List<Map<String, dynamic>> _events() => [
    _event(1, 'membership:human', 'review the CLI'),
    if (_eventCount > 1)
      _event(2, 'membership:assistant', 'done: codex replied'),
  ];

  Map<String, dynamic> _event(int sequence, String author, String text) =>
      <String, dynamic>{
        'id': 'event:$sequence',
        'conversationId': 'lico-group-default',
        'sequence': sequence,
        'authorMembershipId': author,
        'kind': 'message',
        'createdAtUnixMs': 1000 + sequence,
        'finalized': true,
        'parts': [
          {
            'id': 'part:$sequence',
            'eventId': 'event:$sequence',
            'ordinal': 0,
            'kind': 'text',
            'content': text,
            'createdAtUnixMs': 1000 + sequence,
          },
        ],
      };
}
