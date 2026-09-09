import 'dart:convert';

import 'package:licoup/src/contracts/agent_command_runner.dart';

import 'journey_oracle.dart';

const parentId = 'conversation:parent';
const childAId = 'conversation:child-a';
const childBId = 'conversation:child-b';
const goalAId = 'goal:a';
const goalBId = 'goal:b';
const noticeAId = 'notice:a';
const noticeBId = 'notice:b';
const cardAEventId = 'event:card-a';
const cardBEventId = 'event:card-b';
const cardASequence = 2;
const cardBSequence = 4;
const ownerMembershipId = 'membership:parent-owner';
const assistantMembershipId = 'membership:parent-assistant';
const workerAMembershipId = 'membership:child-a-worker';
const reviewerAMembershipId = 'membership:child-a-reviewer';
const workerBMembershipId = 'membership:child-b-worker';
const reviewerBMembershipId = 'membership:child-b-reviewer';
const humanAMembershipId = 'membership:child-a-owner';
const humanBMembershipId = 'membership:child-b-owner';
const sentinelA = 'sentinel-alpha';
const draftInB = 'continuing B without restart';

const postedOrdinaryBeforeA = 'posted ordinary before A';
const startLongWorkA = 'start long work A while waiting';
const postedOrdinaryBetween = 'posted ordinary between A and B';
const askUnrelatedB = 'ask unrelated B while A waits';
const postedOrdinaryAfterB = 'posted ordinary after B';
const scopedContinueA = 'continue A with scoped correction only';
const retryAttemptA = 'retry this A work';
const reviewUpdateA = 'please review A attempt';
const workerAttempt2A = 'worker A attempt 2';
const reviewerUpdatedA = 'reviewer A accepted attempt 2';

/// Exact conversation-bridge stand-in. Records dispatched continuity actions
/// and grows canonical Events from real `conversation.message.post` results.
final class JourneyBridge
    implements AgentCommandRunner, JourneyBridgeTrajectory {
  JourneyBridge({bool prepopulated = true}) : _prepopulated = prepopulated {
    if (prepopulated) {
      _goals[goalAId] = _GoalState(
        childId: childAId,
        sequence: cardASequence,
        eventId: cardAEventId,
        lifecycle: 'active',
        control: 'enabled',
        nextAttention: <String, dynamic>{
          'kind': 'active-execution',
          'executionRef': 'dispatch:a',
        },
      );
      _goals[goalBId] = _GoalState(
        childId: childBId,
        sequence: cardBSequence,
        eventId: cardBEventId,
        lifecycle: 'waiting',
        control: 'enabled',
        nextAttention: <String, dynamic>{
          'kind': 'wait',
          'triggerRef': 'wake:b',
          'reviewPolicy': 'review-on-reply',
          'responsibleParty': ownerMembershipId,
        },
      );
      _parentTimeline.addAll(const <Object>[
        _ParentText('ordinary before A', 1, ownerMembershipId),
        goalAId,
        _ParentText('ordinary between A and B', 3, ownerMembershipId),
        goalBId,
        _ParentText('ordinary after B', 5, ownerMembershipId),
      ]);
      _childEvents[childAId] = <Map<String, dynamic>>[
        _textEvent(childAId, 1, humanAMembershipId, 'delegate notes A'),
        _textEvent(childAId, 2, workerAMembershipId, 'worker A $sentinelA'),
        _textEvent(childAId, 3, reviewerAMembershipId, 'reviewer A accepted'),
      ];
      _childEvents[childBId] = <Map<String, dynamic>>[
        _textEvent(childBId, 1, humanBMembershipId, 'discuss B'),
        _textEvent(childBId, 2, workerBMembershipId, 'worker B progress'),
        for (var sequence = 3; sequence <= 22; sequence += 1)
          _textEvent(
            childBId,
            sequence,
            reviewerBMembershipId,
            'B line $sequence',
          ),
      ];
    }
  }

  factory JourneyBridge.admission() => JourneyBridge(prepopulated: false);

  final bool _prepopulated;
  final Map<String, _GoalState> _goals = <String, _GoalState>{};
  final List<Object> _parentTimeline = <Object>[];
  final Map<String, List<Map<String, dynamic>>> _childEvents =
      <String, List<Map<String, dynamic>>>{};
  final Set<String> _admittedChildren = <String>{};

  @override
  final List<Map<String, dynamic>> requests = <Map<String, dynamic>>[];

  @override
  final List<Map<String, String>> associations = <Map<String, String>>[];

  final List<String> acked = <String>[];
  List<Map<String, dynamic>> pendingNotices = <Map<String, dynamic>>[];
  bool failResolve = false;
  int failNextAfterPost = 0;

  String goalEventId(String goalId) => _goals[goalId]!.eventId;

  int goalSequence(String goalId) => _goals[goalId]!.sequence;

  String goalCardPartId(String goalId) => 'part:${_goals[goalId]!.eventId}';

  void completeGoal(String goalId) {
    final goal = _goals[goalId]!;
    goal.lifecycle = 'achieved';
    goal.control = 'enabled';
    goal.nextAttention = null;
    pendingNotices = <Map<String, dynamic>>[
      ...pendingNotices,
      <String, dynamic>{
        'notificationId': goalId == goalAId ? noticeAId : noticeBId,
        'goalId': goalId,
        'parentConversationId': parentId,
        'childConversationId': goal.childId,
        'cardEventId': goal.eventId,
        'cardSequence': goal.sequence,
      },
    ];
  }

  @override
  Future<Map<String, dynamic>> runCliWithStdin(
    List<String> args,
    String stdinText,
  ) async {
    if (args.length != 4 ||
        args[0] != 'conversation' ||
        args[1] != 'execute' ||
        args[2] != '--stdin-json') {
      throw StateError('unexpected continuity bridge argv');
    }
    final request = Map<String, dynamic>.from(jsonDecode(stdinText) as Map);
    requests.add(request);
    final action = (request['action'] ?? '').toString();
    final conversationId = (request['conversationId'] ?? '').toString();
    if (action == 'resolve-completion-notice' && failResolve) {
      return {
        'ok': false,
        'error': {'code': 'ScopeDenied'},
      };
    }
    if (action == 'conversation.message.post') {
      return _postMessage(request);
    }
    if (action == 'conversation.dispatch.after-post') {
      return _afterPost(request);
    }
    if (action == 'conversation.event.append') {
      return _appendDiagnostic(request);
    }
    if (action == 'conversation.message.delete') {
      _deleteEvent(conversationId, (request['eventId'] ?? '').toString());
      return {'ok': true, 'result': <String, dynamic>{}};
    }
    if (_isContinuityMutation(action)) {
      _applyCommand(action, (request['goalId'] ?? '').toString());
    }
    return {
      'ok': true,
      'result': switch (action) {
        'conversation.list' => _list(),
        'conversation.get' => _conversation(conversationId),
        'conversation.events.page' => _eventsPage(
          conversationId,
          (request['afterSequence'] as num?)?.toInt() ?? 0,
        ),
        'list-pending-completion-notices' => {
          'pendingCompletionNotices': pendingNotices,
        },
        'ack-completion-notices' => {
          'acknowledgedNotificationIds': _ack(request),
        },
        'resolve-completion-notice' => _resolve(request),
        'pause-goal' ||
        'resume-goal' ||
        'correct-association' ||
        'request-cancel' ||
        'close-goal' => <String, dynamic>{
          'ok': true,
          'accepted': true,
          'goalId': request['goalId'],
          'action': action,
        },
        _ => <String, dynamic>{},
      },
    };
  }

  Map<String, dynamic> _postMessage(Map<String, dynamic> request) {
    final conversationId = (request['conversationId'] ?? '').toString();
    final content = (request['content'] ?? '').toString();
    final author = (request['authorMembershipId'] ?? '').toString();
    final event = conversationId == parentId
        ? _postParent(content, author)
        : _appendChildText(conversationId, author, content);
    final eventId = (event['id'] ?? '').toString();
    final goalId = _associate(conversationId, eventId, content);
    return {
      'ok': true,
      'result': <String, dynamic>{
        'event': event,
        'directTurns': <Map<String, dynamic>>[],
        'turns': <Map<String, dynamic>>[],
        'dispatchPending': false,
        'associatedGoalId': ?goalId,
      },
    };
  }

  Map<String, dynamic> _afterPost(Map<String, dynamic> request) {
    if (failNextAfterPost > 0) {
      failNextAfterPost -= 1;
      return {
        'ok': false,
        'error': {'code': 'fixture_turn_failed'},
      };
    }
    final eventId = (request['eventId'] ?? '').toString();
    final conversationId = (request['conversationId'] ?? '').toString();
    Map<String, String>? association;
    for (final item in associations) {
      if (item['eventId'] == eventId) {
        association = item;
        break;
      }
    }
    final content = association?['content'] ?? '';
    final goalId = association?['goalId'] ?? '';
    if (content == retryAttemptA &&
        (conversationId == childAId || goalId == goalAId)) {
      _appendChildText(childAId, workerAMembershipId, workerAttempt2A);
    }
    if (content == reviewUpdateA &&
        (conversationId == childAId || goalId == goalAId)) {
      _appendChildText(childAId, reviewerAMembershipId, reviewerUpdatedA);
    }
    if (content == scopedContinueA && conversationId == parentId) {
      _appendChildText(childAId, humanAMembershipId, scopedContinueA);
    }
    if (content == startLongWorkA && !_childEvents.containsKey(childAId)) {
      _childEvents[childAId] = <Map<String, dynamic>>[
        _textEvent(childAId, 1, humanAMembershipId, startLongWorkA),
      ];
    }
    if (content == askUnrelatedB &&
        !_prepopulated &&
        !_childEvents.containsKey(childBId)) {
      _childEvents[childBId] = <Map<String, dynamic>>[
        _textEvent(childBId, 1, humanBMembershipId, askUnrelatedB),
      ];
    }
    return {
      'ok': true,
      'result': <String, dynamic>{
        'event': <String, dynamic>{'id': eventId},
        'directTurns': <Map<String, dynamic>>[],
        'turns': <Map<String, dynamic>>[],
        'dispatchPending': goalId == goalAId || conversationId == childAId,
      },
    };
  }

  Map<String, dynamic> _appendDiagnostic(Map<String, dynamic> request) {
    final conversationId = (request['conversationId'] ?? '').toString();
    final parts = ((request['parts'] as List?) ?? const <dynamic>[])
        .whereType<Map>()
        .map(Map<String, dynamic>.from)
        .toList(growable: false);
    final sequence = _nextChildSequence(conversationId);
    final eventId = 'event:$conversationId:$sequence';
    final event = <String, dynamic>{
      'id': eventId,
      'conversationId': conversationId,
      'sequence': sequence,
      'authorMembershipId': assistantMembershipIdFor(conversationId),
      'kind': 'message',
      'causationId': (request['causationId'] ?? '').toString(),
      'createdAtUnixMs': 10 + sequence,
      'finalized': request['finalized'] ?? true,
      'parts': <Map<String, dynamic>>[
        for (var index = 0; index < parts.length; index += 1)
          <String, dynamic>{
            'id': 'part:$conversationId:$sequence:$index',
            'eventId': eventId,
            'ordinal': index,
            'kind': (parts[index]['kind'] ?? 'diagnostic').toString(),
            'content': (parts[index]['content'] ?? '').toString(),
            'createdAtUnixMs': 10 + sequence,
          },
      ],
    };
    _childEvents
        .putIfAbsent(conversationId, () => <Map<String, dynamic>>[])
        .add(event);
    return {'ok': true, 'result': event};
  }

  Map<String, dynamic> _postParent(String content, String author) {
    if (content == startLongWorkA && !_goals.containsKey(goalAId)) {
      return _admitParentGoal(
        goalId: goalAId,
        childId: childAId,
        author: author,
        lifecycle: 'active',
        nextAttention: <String, dynamic>{
          'kind': 'active-execution',
          'executionRef': 'dispatch:a',
        },
      );
    }
    if (content == askUnrelatedB && !_goals.containsKey(goalBId)) {
      return _admitParentGoal(
        goalId: goalBId,
        childId: childBId,
        author: author,
        lifecycle: 'waiting',
        nextAttention: <String, dynamic>{
          'kind': 'wait',
          'triggerRef': 'wake:b',
          'reviewPolicy': 'review-on-reply',
          'responsibleParty': ownerMembershipId,
        },
      );
    }
    final sequence = _parentTimeline.length + 1;
    final item = _ParentText(content, sequence, author);
    _parentTimeline.add(item);
    return item.toEvent();
  }

  Map<String, dynamic> _admitParentGoal({
    required String goalId,
    required String childId,
    required String author,
    required String lifecycle,
    required Map<String, dynamic> nextAttention,
  }) {
    final sequence = _parentTimeline.length + 1;
    final eventId = 'event:$parentId:$sequence';
    _goals[goalId] = _GoalState(
      childId: childId,
      sequence: sequence,
      eventId: eventId,
      lifecycle: lifecycle,
      control: 'enabled',
      nextAttention: nextAttention,
    );
    _parentTimeline.add(goalId);
    _admittedChildren.add(childId);
    _childEvents.putIfAbsent(childId, () => <Map<String, dynamic>>[]);
    return _cardEvent(_goals[goalId]!, goalId);
  }

  Map<String, dynamic> _appendChildText(
    String conversationId,
    String author,
    String content,
  ) {
    final sequence = _nextChildSequence(conversationId);
    final event = _textEvent(conversationId, sequence, author, content);
    _childEvents
        .putIfAbsent(conversationId, () => <Map<String, dynamic>>[])
        .add(event);
    return event;
  }

  int _nextChildSequence(String conversationId) {
    final events =
        _childEvents[conversationId] ?? const <Map<String, dynamic>>[];
    var highest = 0;
    for (final event in events) {
      final sequence = (event['sequence'] as num?)?.toInt() ?? 0;
      if (sequence > highest) {
        highest = sequence;
      }
    }
    return highest + 1;
  }

  String? _associate(String conversationId, String eventId, String content) {
    String? goalId;
    if (conversationId == childAId ||
        content == startLongWorkA ||
        content == scopedContinueA ||
        content == retryAttemptA ||
        content == reviewUpdateA) {
      goalId = goalAId;
    } else if (conversationId == childBId || content == askUnrelatedB) {
      goalId = goalBId;
    }
    associations.add(<String, String>{
      'eventId': eventId,
      'conversationId': conversationId,
      'goalId': goalId ?? '',
      'content': content,
    });
    return goalId;
  }

  void _deleteEvent(String conversationId, String eventId) {
    if (conversationId == parentId) {
      _parentTimeline.removeWhere((item) {
        if (item is _ParentText) {
          return item.toEvent()['id'] == eventId;
        }
        if (item is String) {
          return _goals[item]?.eventId == eventId;
        }
        return false;
      });
      return;
    }
    _childEvents[conversationId]?.removeWhere(
      (event) => (event['id'] ?? '').toString() == eventId,
    );
  }

  bool _isContinuityMutation(String action) {
    return action == 'pause-goal' ||
        action == 'resume-goal' ||
        action == 'correct-association' ||
        action == 'request-cancel';
  }

  void _applyCommand(String action, String goalId) {
    final goal = _goals[goalId];
    if (goal == null) return;
    switch (action) {
      case 'pause-goal':
        goal.control = 'paused';
        goal.nextAttention = null;
      case 'resume-goal':
        goal.control = 'enabled';
        goal.lifecycle = 'active';
        goal.nextAttention = <String, dynamic>{
          'kind': 'active-execution',
          'executionRef': 'dispatch:$goalId',
        };
      case 'correct-association':
        goal.lifecycle = 'active';
        goal.control = 'enabled';
      case 'request-cancel':
        goal.control = 'cancel-requested';
    }
  }

  List<String> _ack(Map<String, dynamic> request) {
    final ids = ((request['notificationIds'] as List?) ?? const <dynamic>[])
        .map((id) => id.toString())
        .where((id) => id.isNotEmpty)
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

  Map<String, dynamic> _resolve(Map<String, dynamic> request) {
    final notificationId = (request['notificationId'] ?? '').toString();
    final goalId = notificationId == noticeBId ? goalBId : goalAId;
    final goal = _goals[goalId]!;
    return <String, dynamic>{
      'ok': true,
      'notificationId': notificationId,
      'goalId': goalId,
      'parentConversationId': parentId,
      'childConversationId': goal.childId,
      'cardEventId': goal.eventId,
      'cardSequence': goal.sequence,
    };
  }

  List<Map<String, dynamic>> _list() {
    return <Map<String, dynamic>>[
      _summary(
        parentId,
        title: 'Parent',
        eventCount: _events(parentId).length,
        membershipCount: 2,
      ),
      if (_showsChild(childAId))
        _summary(
          childAId,
          title: 'Child A',
          eventCount: _events(childAId).length,
          membershipCount: 4,
          parent: parentId,
          goalId: goalAId,
        ),
      if (_showsChild(childBId))
        _summary(
          childBId,
          title: 'Child B',
          eventCount: _events(childBId).length,
          membershipCount: 4,
          parent: parentId,
          goalId: goalBId,
        ),
    ];
  }

  bool _showsChild(String childId) {
    return _prepopulated || _admittedChildren.contains(childId);
  }

  Map<String, dynamic> _summary(
    String id, {
    required String title,
    required int eventCount,
    required int membershipCount,
    String? parent,
    String? goalId,
  }) {
    return <String, dynamic>{
      'id': id,
      'title': title,
      'archived': false,
      'pinned': false,
      'isGroup': true,
      'revision': 1,
      'updatedAtUnixMs': 20,
      'membershipCount': membershipCount,
      'eventCount': eventCount,
      'parentConversationId': ?parent,
      'taskGoalId': ?goalId,
      if (parent != null) 'listingKind': 'child-task',
    };
  }

  Map<String, dynamic> _conversation(String id) {
    return switch (id) {
      childAId => _childConversation(
        id,
        title: 'Child A',
        eventCount: _events(id).length,
        assistantId: 'membership:child-a-assistant',
        memberships: <Map<String, dynamic>>[
          _membership(
            humanAMembershipId,
            id,
            principalId: 'human:local',
            kind: 'human',
            name: 'You',
            access: 'owner',
          ),
          _membership(
            'membership:child-a-assistant',
            id,
            principalId: 'agent:codex',
            kind: 'agent',
            name: 'Assistant',
            agentId: 'codex',
          ),
          _membership(
            workerAMembershipId,
            id,
            principalId: 'agent:worker',
            kind: 'agent',
            name: 'Worker A',
            agentId: 'worker',
          ),
          _membership(
            reviewerAMembershipId,
            id,
            principalId: 'agent:reviewer',
            kind: 'agent',
            name: 'Reviewer A',
            agentId: 'reviewer',
          ),
        ],
        taskViews: <Map<String, dynamic>>[
          if (_goals.containsKey(goalAId)) _taskView(_goals[goalAId]!),
        ],
      ),
      childBId => _childConversation(
        id,
        title: 'Child B',
        eventCount: _events(id).length,
        assistantId: 'membership:child-b-assistant',
        memberships: <Map<String, dynamic>>[
          _membership(
            humanBMembershipId,
            id,
            principalId: 'human:local',
            kind: 'human',
            name: 'You',
            access: 'owner',
          ),
          _membership(
            'membership:child-b-assistant',
            id,
            principalId: 'agent:codex',
            kind: 'agent',
            name: 'Assistant',
            agentId: 'codex',
          ),
          _membership(
            workerBMembershipId,
            id,
            principalId: 'agent:worker',
            kind: 'agent',
            name: 'Worker B',
            agentId: 'worker',
          ),
          _membership(
            reviewerBMembershipId,
            id,
            principalId: 'agent:reviewer',
            kind: 'agent',
            name: 'Reviewer B',
            agentId: 'reviewer',
          ),
        ],
        taskViews: <Map<String, dynamic>>[
          if (_goals.containsKey(goalBId)) _taskView(_goals[goalBId]!),
        ],
      ),
      _ => _childConversation(
        parentId,
        title: 'Parent',
        eventCount: _events(parentId).length,
        assistantId: assistantMembershipId,
        memberships: <Map<String, dynamic>>[
          _membership(
            ownerMembershipId,
            parentId,
            principalId: 'human:local',
            kind: 'human',
            name: 'You',
            access: 'owner',
          ),
          _membership(
            assistantMembershipId,
            parentId,
            principalId: 'agent:codex',
            kind: 'agent',
            name: 'Assistant',
            agentId: 'codex',
          ),
        ],
        taskViews: <Map<String, dynamic>>[
          for (final goal in _goals.values) _taskView(goal),
        ],
      ),
    };
  }

  Map<String, dynamic> _childConversation(
    String id, {
    required String title,
    required int eventCount,
    required String assistantId,
    required List<Map<String, dynamic>> memberships,
    required List<Map<String, dynamic>> taskViews,
  }) {
    return <String, dynamic>{
      'id': id,
      'title': title,
      'archived': false,
      'pinned': false,
      'isGroup': true,
      'revision': 1,
      'createdAtUnixMs': 1,
      'updatedAtUnixMs': 20,
      'eventCount': eventCount,
      'assistantMembershipId': assistantId,
      'memberships': memberships,
      'taskViews': taskViews,
    };
  }

  Map<String, dynamic> _membership(
    String id,
    String conversationId, {
    required String principalId,
    required String kind,
    required String name,
    String access = 'member',
    String? agentId,
  }) {
    return <String, dynamic>{
      'id': id,
      'conversationId': conversationId,
      'principal': <String, dynamic>{
        'id': principalId,
        'kind': kind,
        'displayName': name,
        'createdAtUnixMs': 1,
        'agentId': ?agentId,
      },
      'access': access,
      'status': 'active',
      'joinedAtUnixMs': 1,
    };
  }

  Map<String, dynamic> _taskView(_GoalState goal) {
    final goalId = _goals.entries
        .firstWhere((entry) => identical(entry.value, goal))
        .key;
    return <String, dynamic>{
      'id': goalId,
      'relation': <String, dynamic>{
        'goalId': goalId,
        'parentConversationId': parentId,
        'childConversationId': goal.childId,
        'listingKind': 'child-task',
        'followThroughKind': 'durable',
        'revision': 1,
        'cardAnchor': <String, dynamic>{
          'parentConversationId': parentId,
          'eventId': goal.eventId,
          'sequence': goal.sequence,
        },
        'createdEvent': <String, dynamic>{
          'ownerKind': 'event',
          'opaqueId': goal.eventId,
          'sourceRevision': goal.sequence,
          'digest': 'event:${goal.eventId}',
          'visibilityScope': 'conversation',
          'validity': 'current',
        },
      },
      'progress': <String, dynamic>{
        'goalId': goalId,
        'revision': 1,
        'lifecycle': goal.lifecycle,
        'control': goal.control,
        'criterionEvidenceRefs': <Map<String, dynamic>>[],
        'activeExecutionRefs': goal.nextAttention == null
            ? <String>[]
            : <String>[
                (goal.nextAttention!['executionRef'] ?? '').toString(),
              ].where((item) => item.isNotEmpty).toList(),
        'blockers': <String>[],
        if (goal.nextAttention != null) 'nextAttention': goal.nextAttention,
      },
    };
  }

  Map<String, dynamic> _eventsPage(String conversationId, int afterSequence) {
    final events = _events(conversationId)
        .where((event) => (event['sequence'] as int) > afterSequence)
        .toList(growable: false);
    return <String, dynamic>{
      'events': events,
      'nextCursor': null,
      'totalCount': _events(conversationId).length,
    };
  }

  List<Map<String, dynamic>> _events(String conversationId) {
    if (conversationId == parentId) {
      return <Map<String, dynamic>>[
        for (final item in _parentTimeline)
          if (item is String)
            _cardEvent(_goals[item]!, item)
          else
            (item as _ParentText).toEvent(),
      ];
    }
    return List<Map<String, dynamic>>.from(
      _childEvents[conversationId] ?? const <Map<String, dynamic>>[],
    );
  }

  Map<String, dynamic> _cardEvent(_GoalState goal, String goalId) {
    return <String, dynamic>{
      'id': goal.eventId,
      'conversationId': parentId,
      'sequence': goal.sequence,
      'authorMembershipId': ownerMembershipId,
      'kind': 'message',
      'createdAtUnixMs': 10 + goal.sequence,
      'finalized': true,
      'parts': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'part:${goal.eventId}',
          'eventId': goal.eventId,
          'ordinal': 0,
          'kind': 'metadata',
          'content': jsonEncode(<String, dynamic>{
            'goalId': goalId,
            'childConversationId': goal.childId,
            'toLifecycle': goal.lifecycle,
            'sequence': goal.sequence,
          }),
          'createdAtUnixMs': 10 + goal.sequence,
        },
      ],
    };
  }

  Map<String, dynamic> _textEvent(
    String conversationId,
    int sequence,
    String authorMembershipId,
    String text,
  ) {
    return <String, dynamic>{
      'id': 'event:$conversationId:$sequence',
      'conversationId': conversationId,
      'sequence': sequence,
      'authorMembershipId': authorMembershipId,
      'kind': 'message',
      'createdAtUnixMs': 10 + sequence,
      'finalized': true,
      'parts': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'part:$conversationId:$sequence',
          'eventId': 'event:$conversationId:$sequence',
          'ordinal': 0,
          'kind': 'text',
          'content': text,
          'createdAtUnixMs': 10 + sequence,
        },
      ],
    };
  }

  String assistantMembershipIdFor(String conversationId) {
    return switch (conversationId) {
      childAId => 'membership:child-a-assistant',
      childBId => 'membership:child-b-assistant',
      _ => assistantMembershipId,
    };
  }

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

final class _ParentText {
  const _ParentText(this.text, this.sequence, this.authorMembershipId);

  final String text;
  final int sequence;
  final String authorMembershipId;

  Map<String, dynamic> toEvent() {
    return <String, dynamic>{
      'id': 'event:$parentId:$sequence',
      'conversationId': parentId,
      'sequence': sequence,
      'authorMembershipId': authorMembershipId,
      'kind': 'message',
      'createdAtUnixMs': 10 + sequence,
      'finalized': true,
      'parts': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'part:$parentId:$sequence',
          'eventId': 'event:$parentId:$sequence',
          'ordinal': 0,
          'kind': 'text',
          'content': text,
          'createdAtUnixMs': 10 + sequence,
        },
      ],
    };
  }
}

final class _GoalState {
  _GoalState({
    required this.childId,
    required this.sequence,
    required this.eventId,
    required this.lifecycle,
    required this.control,
    this.nextAttention,
  });

  final String childId;
  final int sequence;
  final String eventId;
  String lifecycle;
  String control;
  Map<String, dynamic>? nextAttention;
}
