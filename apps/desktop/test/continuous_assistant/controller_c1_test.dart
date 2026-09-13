import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/application/features/conversations/client_conversation_controller.dart';
import 'package:licoup/src/contracts/conversation_native_port.dart';
import 'package:licoup/src/contracts/generated/conversation.g.dart';

void main() {
  setUp(() {
    const noProxy = 'localhost,127.0.0.1,::1';
    HttpOverrides.global = null;
    expect(noProxy.contains('localhost'), isTrue);
  });

  test('late A get after B finishes does not overwrite B taskViews', () async {
    final delayA = Completer<void>();
    final runner = _ContinuityBridgeRunner(
      delayGetFor: 'conversation:a',
      gate: delayA,
    );
    final controller = ClientConversationController(
      native: runner,
      pendingNoticePollInterval: const Duration(hours: 1),
    );
    await controller.initialize();

    final selectA = controller.selectConversation('conversation:a');
    await Future<void>.delayed(Duration.zero);
    await controller.selectConversation('conversation:b');
    expect(controller.selectedConversationId, 'conversation:b');
    expect(controller.selectedTaskViews.single['id'], 'task-b');

    delayA.complete();
    await selectA;
    expect(controller.selectedConversationId, 'conversation:b');
    expect(controller.selectedTaskViews.single['id'], 'task-b');
    controller.dispose();
  });

  test('close-goal acceptance does not queue or consume a notice', () async {
    final runner = _ContinuityBridgeRunner();
    final controller = ClientConversationController(
      native: runner,
      pendingNoticePollInterval: const Duration(hours: 1),
    );
    await controller.initialize();
    await controller.selectConversation('conversation:b');
    await Future<void>.delayed(Duration.zero);
    runner.requests.clear();
    await controller.executeContinuityCommand(
      conversationId: 'conversation:b',
      command: ContinuityCommand.closeGoal,
      goalId: 'goal:one',
      extra: {
        'transition': {'notificationId': 'notice:one'},
        'progress': {'goalId': 'goal:one'},
      },
    );
    expect(controller.takeFreshCompletionNotices(), isEmpty);
    expect(
      runner.requests.where((request) => request['action'] == 'close-goal'),
      hasLength(1),
    );
    expect(controller.selectedConversationId, 'conversation:b');
    controller.dispose();
  });

  test('reversed B then late A does not steal focus or B taskViews', () async {
    final delayA = Completer<void>();
    final runner = _ContinuityBridgeRunner(
      delayGetFor: 'conversation:a',
      gate: delayA,
    );
    final controller = ClientConversationController(
      native: runner,
      pendingNoticePollInterval: const Duration(hours: 1),
    );
    await controller.initialize();
    await controller.selectConversation('conversation:b');
    expect(controller.selectedConversationId, 'conversation:b');
    final selectA = controller.selectConversation('conversation:a');
    await Future<void>.delayed(Duration.zero);
    expect(controller.selectedConversationId, 'conversation:a');
    await controller.selectConversation('conversation:b');
    delayA.complete();
    await selectA;
    expect(controller.selectedConversationId, 'conversation:b');
    expect(controller.selectedTaskViews.single['id'], 'task-b');
    controller.dispose();
  });

  test(
    'card event beyond newest-20 is recovered by sequence without tail reinsert',
    () async {
      final runner = _WindowedBridgeRunner();
      final controller = ClientConversationController(
        native: runner,
        pendingNoticePollInterval: const Duration(hours: 1),
      );
      await controller.initialize();
      await controller.selectConversation('conversation:wide');
      expect(controller.events.map((event) => event.sequence), [
        3,
        ...List.generate(20, (index) => index + 41),
      ]);
      expect(controller.events.last.sequence, 60);
      expect(controller.events.first.sequence, 3);
      expect(controller.events.first.id, 'event:card-3');
      controller.dispose();
    },
  );

  test(
    'get while B is selected cannot deliver or consume A notice fields',
    () async {
      final runner = _ContinuityBridgeRunner(
        getNoticeFieldsFor: 'conversation:b',
      );
      final controller = ClientConversationController(
        native: runner,
        pendingNoticePollInterval: const Duration(hours: 1),
      );
      await controller.initialize();
      await controller.selectConversation('conversation:b');
      expect(controller.selectedConversationId, 'conversation:b');
      expect(controller.takeFreshCompletionNotices(), isEmpty);
      expect(controller.selectedTaskViews.single['id'], 'task-b');
      controller.dispose();
    },
  );

  test(
    'idle B poll queues A notice without refresh, get, or focus steal',
    () async {
      final runner = _ContinuityBridgeRunner();
      final controller = ClientConversationController(
        native: runner,
        pendingNoticePollInterval: const Duration(milliseconds: 20),
      );
      await controller.initialize();
      await controller.selectConversation('conversation:b');
      controller.updateDraft('keep composing');
      expect(controller.takeFreshCompletionNotices(), isEmpty);
      runner.requests.clear();
      runner.pendingNotices = <Map<String, dynamic>>[
        <String, dynamic>{
          'notificationId': 'notice:a',
          'goalId': 'goal:a',
          'parentConversationId': 'conversation:a',
          'childConversationId': 'conversation:child-a',
          'cardEventId': 'event:card-a',
          'cardSequence': 4,
        },
      ];
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(
        runner.requests.where(
          (request) => request['action'] == 'conversation.get',
        ),
        isEmpty,
      );
      expect(
        runner.requests.where(
          (request) => request['action'] == 'conversation.list',
        ),
        isEmpty,
      );
      expect(
        runner.requests.where(
          (request) => request['action'] == 'list-pending-completion-notices',
        ),
        isNotEmpty,
      );
      expect(controller.selectedConversationId, 'conversation:b');
      expect(controller.draft, 'keep composing');
      expect(controller.selectedTaskViews.single['id'], 'task-b');
      final notices = controller.takeFreshCompletionNotices();
      expect(notices, hasLength(1));
      expect(notices.single['notificationId'], 'notice:a');
      expect(controller.takeFreshCompletionNotices(), isEmpty);
      controller.dispose();
    },
  );

  test('failed list retains pending; ack after publish is once-only', () async {
    final runner = _ContinuityBridgeRunner()..failList = true;
    final controller = ClientConversationController(
      native: runner,
      pendingNoticePollInterval: const Duration(hours: 1),
    );
    await controller.initialize();
    await controller.selectConversation('conversation:b');
    runner.pendingNotices = <Map<String, dynamic>>[
      <String, dynamic>{
        'notificationId': 'notice:a',
        'goalId': 'goal:a',
        'parentConversationId': 'conversation:a',
        'childConversationId': 'conversation:child-a',
        'cardEventId': 'event:card-a',
        'cardSequence': 4,
      },
    ];
    await controller.selectConversation('conversation:a');
    await controller.selectConversation('conversation:b');
    expect(controller.takeFreshCompletionNotices(), isEmpty);
    runner.failList = false;
    await controller.selectConversation('conversation:a');
    await controller.selectConversation('conversation:b');
    await Future<void>.delayed(Duration.zero);
    final notices = controller.takeFreshCompletionNotices();
    expect(notices.single['notificationId'], 'notice:a');
    controller.acknowledgePublishedCompletionNotices(['notice:a']);
    await Future<void>.delayed(Duration.zero);
    expect(runner.acked, ['notice:a']);
    expect(controller.takeFreshCompletionNotices(), isEmpty);
    await controller.selectConversation('conversation:a');
    await controller.selectConversation('conversation:b');
    expect(controller.takeFreshCompletionNotices(), isEmpty);
    controller.dispose();
  });

  test('denied ack prefix does not starve later eligible notices', () async {
    final runner = _ContinuityBridgeRunner();
    final controller = ClientConversationController(
      native: runner,
      pendingNoticePollInterval: const Duration(hours: 1),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.selectConversation('conversation:b');
    final denied = List.generate(50, (index) => 'notice:denied-$index');
    runner.deniedAcks.addAll(denied);
    controller.acknowledgePublishedCompletionNotices([
      ...denied,
      'notice:eligible',
    ]);
    await Future<void>.delayed(Duration.zero);
    expect(runner.acked, ['notice:eligible']);
    final requests = runner.requests.where(
      (request) => request['action'] == 'ack-completion-notices',
    );
    expect(
      requests.map((request) => (request['notificationIds'] as List).length),
      [50, 1],
    );
    runner.deniedAcks.clear();
    await controller.pollPendingCompletionNotices();
    expect(runner.acked, containsAll(denied));
  });

  test(
    'activate uses current resolve target; forged resolve has zero effect',
    () async {
      final runner = _ContinuityBridgeRunner();
      final controller = ClientConversationController(
        native: runner,
        pendingNoticePollInterval: const Duration(hours: 1),
      );
      await controller.initialize();
      await controller.selectConversation('conversation:b');
      runner.failResolve = true;
      await controller.activateCompletionNotice(
        notificationId: 'notice:forged',
      );
      expect(controller.selectedConversationId, 'conversation:b');
      runner.failResolve = false;
      await controller.activateCompletionNotice(notificationId: 'notice:a');
      expect(controller.selectedConversationId, 'conversation:child-a');
      expect(controller.selectedConversation?.id, 'conversation:child-a');
      controller.dispose();
    },
  );
}

final class _ContinuityBridgeRunner implements ClientConversationNativePort {
  _ContinuityBridgeRunner({
    this.delayGetFor,
    this.gate,
    this.getNoticeFieldsFor,
  });

  final String? delayGetFor;
  final Completer<void>? gate;
  final String? getNoticeFieldsFor;
  final List<Map<String, dynamic>> requests = [];
  List<Map<String, dynamic>> pendingNotices = <Map<String, dynamic>>[];
  final List<String> acked = <String>[];
  final Set<String> deniedAcks = <String>{};
  bool failList = false;
  bool failAck = false;
  bool failResolve = false;

  @override
  Future<Map<String, dynamic>> executeClientConversation(
    ClientConversationCommand command,
  ) async {
    final request = command.payload;
    requests.add(request);
    final action = request['action'];
    final conversationId = (request['conversationId'] ?? '').toString();
    if (action == 'conversation.get' &&
        delayGetFor != null &&
        conversationId == delayGetFor) {
      await gate?.future;
    }
    if (action == 'list-pending-completion-notices' && failList) {
      return {
        'ok': false,
        'error': {'code': 'ScopeDenied'},
      };
    }
    if (action == 'ack-completion-notices' && failAck) {
      return {
        'ok': false,
        'error': {'code': 'SourceUnavailable'},
      };
    }
    if (action == 'resolve-completion-notice' && failResolve) {
      return {
        'ok': false,
        'error': {'code': 'ScopeDenied'},
      };
    }
    return {
      'ok': true,
      'result': switch (action) {
        'conversation.list' => [
          _summary('conversation:a'),
          _summary('conversation:b'),
        ],
        'conversation.get' => {
          ..._conversation(conversationId),
          if (getNoticeFieldsFor != null &&
              conversationId == getNoticeFieldsFor)
            'freshCompletionNotices': <Map<String, dynamic>>[
              <String, dynamic>{
                'notificationId': 'notice:foreign',
                'goalId': 'goal:a',
                'parentConversationId': 'conversation:a',
                'childConversationId': 'conversation:child-a',
                'cardEventId': 'event:card-a',
                'cardSequence': 4,
              },
            ],
        },
        'conversation.events.page' => {
          'events': [_event(conversationId)],
          'nextCursor': null,
          'totalCount': 1,
        },
        'close-goal' => {
          'ok': true,
          'accepted': true,
          'notificationId':
              (((request['transition'] as Map?)?['notificationId']) ?? '')
                  .toString(),
        },
        'list-pending-completion-notices' => {
          'pendingCompletionNotices': pendingNotices,
        },
        'ack-completion-notices' => {
          'acknowledgedNotificationIds': _ack(request),
        },
        'resolve-completion-notice' => {
          'ok': true,
          'notificationId': request['notificationId'],
          'goalId': 'goal:a',
          'parentConversationId': 'conversation:a',
          'childConversationId': 'conversation:child-a',
          'cardEventId': 'event:card-a',
          'cardSequence': 4,
        },
        _ => <String, dynamic>{},
      },
    };
  }

  List<String> _ack(Map<String, dynamic> request) {
    final ids = ((request['notificationIds'] as List?) ?? const <dynamic>[])
        .map((id) => id.toString())
        .where((id) => id.isNotEmpty)
        .take(50)
        .where((id) => !deniedAcks.contains(id))
        .toList(growable: false);
    acked.addAll(ids);
    pendingNotices = pendingNotices
        .where(
          (notice) =>
              !ids.contains((notice['notificationId'] ?? '').toString()),
        )
        .toList();
    return ids;
  }
}

Map<String, dynamic> _summary(String id) => {
  'id': id,
  'title': id,
  'archived': false,
  'pinned': false,
  'isGroup': true,
  'revision': 1,
  'updatedAtUnixMs': 10,
  'membershipCount': 2,
  'eventCount': 1,
};

Map<String, dynamic> _conversation(String id) => {
  'id': id,
  'title': id,
  'archived': false,
  'pinned': false,
  'isGroup': true,
  'revision': 1,
  'createdAtUnixMs': 1,
  'updatedAtUnixMs': 10,
  'eventCount': 1,
  'memberships': [
    {
      'id': 'membership:owner',
      'conversationId': id,
      'principal': {
        'id': 'human:local',
        'kind': 'human',
        'displayName': 'You',
        'createdAtUnixMs': 1,
      },
      'access': 'owner',
      'status': 'active',
      'joinedAtUnixMs': 1,
    },
  ],
  'taskViews': [
    {'id': id == 'conversation:a' ? 'task-a' : 'task-b', 'conversationId': id},
  ],
};

final class _WindowedBridgeRunner implements ClientConversationNativePort {
  @override
  Future<Map<String, dynamic>> executeClientConversation(
    ClientConversationCommand command,
  ) async {
    final request = command.payload;
    final action = request['action'];
    final afterSequence = (request['afterSequence'] as num?)?.toInt() ?? 0;
    return {
      'ok': true,
      'result': switch (action) {
        'conversation.list' => [
          _summary('conversation:wide')..['eventCount'] = 60,
        ],
        'conversation.get' => {
          ..._conversation('conversation:wide'),
          'eventCount': 60,
          'taskViews': [
            {
              'id': 'task-old',
              'relation': {
                'cardAnchor': {
                  'parentConversationId': 'conversation:wide',
                  'eventId': 'event:card-3',
                  'sequence': 3,
                },
              },
            },
          ],
        },
        'conversation.events.page' =>
          request['latest'] == true
              ? {
                  'events': [
                    for (var sequence = 41; sequence <= 60; sequence += 1)
                      _eventAt('conversation:wide', sequence),
                  ],
                  'nextCursor': null,
                  'totalCount': 60,
                  'hasEarlier': true,
                  'nextBeforeSequence': 41,
                }
              : {
                  'events': [_eventAt('conversation:wide', afterSequence + 1)],
                  'nextCursor': null,
                  'totalCount': 60,
                },
        'list-pending-completion-notices' => {
          'pendingCompletionNotices': <Map<String, dynamic>>[],
        },
        _ => <String, dynamic>{},
      },
    };
  }
}

Map<String, dynamic> _eventAt(String conversationId, int sequence) => {
  'id': sequence == 3 ? 'event:card-3' : 'event:$conversationId:$sequence',
  'conversationId': conversationId,
  'sequence': sequence,
  'authorMembershipId': 'membership:owner',
  'kind': 'message',
  'createdAtUnixMs': 10 + sequence,
  'finalized': true,
  'parts': [
    {
      'id': 'part:$sequence',
      'eventId': 'event:$conversationId:$sequence',
      'ordinal': 0,
      'kind': 'metadata',
      'content': 'card $sequence',
      'createdAtUnixMs': 10 + sequence,
    },
  ],
};

Map<String, dynamic> _event(String conversationId) => {
  'id': 'event:$conversationId',
  'conversationId': conversationId,
  'sequence': 1,
  'authorMembershipId': 'membership:owner',
  'kind': 'message',
  'createdAtUnixMs': 10,
  'finalized': true,
  'parts': [
    {
      'id': 'part:text',
      'eventId': 'event:$conversationId',
      'ordinal': 0,
      'kind': 'text',
      'content': 'hello',
      'createdAtUnixMs': 10,
    },
  ],
};
