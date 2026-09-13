import 'dart:async';

import 'package:licoup/src/contracts/conversation_native_port.dart';

/// Synthetic event store with real sequence gaps and both native page directions.
final class PagedConversationNative implements ClientConversationNativePort {
  PagedConversationNative({int count = 65, this.cardSequence}) {
    appendThrough(count);
  }

  final List<Map<String, dynamic>> requests = [];
  final Map<int, Map<String, dynamic>> events = {};
  int? cardSequence;
  int revision = 1;
  bool failEarlier = false;
  Completer<void>? earlierGate;
  Completer<void>? anchorGate;

  void appendThrough(int last) {
    final start = events.keys.lastOrNull ?? 0;
    for (var sequence = start + 1; sequence <= last; sequence += 1) {
      events[sequence] = _event(sequence);
    }
    revision += 1;
  }

  List<Map<String, dynamic>> get pageRequests => requests
      .where((request) => request['action'] == 'conversation.events.page')
      .toList();

  @override
  Future<Map<String, dynamic>> executeClientConversation(
    ClientConversationCommand command,
  ) async {
    final request = command.payload;
    requests.add(Map.of(request));
    final id = (request['conversationId'] ?? 'group').toString();
    final Object result;
    switch (request['action']) {
      case 'conversation.list':
        result = [_conversation('group'), _conversation('other')];
      case 'conversation.get':
        result = _conversation(id);
      case 'conversation.events.page':
        final before = request['beforeSequence'] as int?;
        final after = request['afterSequence'] as int?;
        final limit = request['limit'] as int;
        if (before != null) {
          await earlierGate?.future;
          if (failEarlier) {
            return {
              'ok': false,
              'error': {'code': 'synthetic_page_unavailable'},
            };
          }
        }
        if (limit == 1) await anchorGate?.future;
        final available =
            id == 'other' ? <Map<String, dynamic>>[] : events.values.toList()
              ..sort(
                (a, b) =>
                    (a['sequence'] as int).compareTo(b['sequence'] as int),
              );
        final backwards = request['latest'] == true || before != null;
        var selected = available.where((event) {
          final sequence = event['sequence'] as int;
          return (before == null || sequence < before) &&
              (after == null || sequence > after);
        }).toList();
        selected = backwards
            ? selected
                  .skip((selected.length - limit).clamp(0, selected.length))
                  .toList()
            : selected.take(limit).toList();
        final earliest = selected.firstOrNull?['sequence'] as int?;
        final hasEarlier =
            earliest != null &&
            available.any((event) => (event['sequence'] as int) < earliest);
        result = {
          'events': selected,
          'totalCount': available.length,
          'nextCursor': selected.lastOrNull?['sequence']?.toString(),
          'hasEarlier': hasEarlier,
          'nextBeforeSequence': hasEarlier ? earliest : null,
        };
      case 'conversation.clear':
        events.clear();
        revision += 1;
        result = {};
      case 'conversation.message.delete':
        events.removeWhere((_, event) => event['id'] == request['eventId']);
        revision += 1;
        result = {};
      case 'list-pending-completion-notices':
        result = {'pendingCompletionNotices': <Map<String, dynamic>>[]};
      default:
        result = {};
    }
    return {'ok': true, 'result': result};
  }

  Map<String, dynamic> _conversation(String id) => {
    'id': id,
    'title': 'Synthetic conversation',
    'isGroup': true,
    'revision': revision,
    'eventCount': id == 'other' ? 0 : events.length,
    'createdAtUnixMs': 1,
    'updatedAtUnixMs': revision,
    'memberships': [
      for (final human in [true, false])
        {
          'id': human ? 'owner' : 'agent',
          'conversationId': id,
          'principal': {
            'id': human ? 'human:local' : 'agent:codex',
            'kind': human ? 'human' : 'agent',
            'displayName': human ? 'You' : 'Codex',
            if (!human) 'agentId': 'codex',
          },
          'access': human ? 'owner' : 'member',
          'status': 'active',
        },
    ],
    'taskViews': [
      if (cardSequence != null && events.containsKey(cardSequence))
        {
          'id': 'task',
          'relation': {
            'cardAnchor': {
              'parentConversationId': id,
              'eventId': 'event-$cardSequence',
              'sequence': cardSequence,
            },
          },
        },
    ],
  };

  Map<String, dynamic> _event(int sequence) => {
    'id': 'event-$sequence',
    'conversationId': 'group',
    'sequence': sequence,
    'authorMembershipId': sequence.isEven ? 'owner' : 'agent',
    'kind': 'message',
    'createdAtUnixMs': sequence * 1000,
    'finalized': true,
    'parts': [
      {
        'id': 'part-$sequence',
        'eventId': 'event-$sequence',
        'ordinal': 0,
        'kind': 'text',
        'content': 'Canonical message $sequence\n\nRetained content',
        'createdAtUnixMs': sequence * 1000,
      },
    ],
  };
}
