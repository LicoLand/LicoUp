import 'package:licoup/src/contracts/client_conversation_models.dart';
import 'package:licoup/src/contracts/generated/conversation.g.dart';

/// Event-driven most-recently-used order for one canonical conversation's
/// Agent participants.
///
/// A hash index plus an intrusive doubly linked list makes a speaker promotion
/// O(1). Full reconciliation happens only when membership or discovered-Agent
/// inputs change; ordinary widget rebuilds only read the already ordered head.
final class ClientConversationRecentParticipants {
  final _queue = _RecentParticipantQueue();
  String _conversationId = '';
  int _lastAppliedSequence = 0;
  List<String> _candidateAgentIds = const [];

  List<String> get agentIds => _queue.snapshot();

  bool applySnapshot({
    required ClientConversation conversation,
    required List<ClientConversationEvent> events,
    Iterable<String> availableLocalAgentIds = const [],
  }) {
    final membershipById = <String, String>{};
    final candidateAgentIds = <String>[];
    final seenCandidates = <String>{};
    for (final membership in conversation.activeAgentMemberships) {
      final agentId = membership.principal.agentId.trim();
      if (agentId.isEmpty) continue;
      membershipById[membership.id] = agentId;
      if (seenCandidates.add(agentId)) candidateAgentIds.add(agentId);
    }
    if (conversation.isDefaultLocalAgentGroup) {
      for (final value in availableLocalAgentIds) {
        final agentId = value.trim();
        if (agentId.isNotEmpty && seenCandidates.add(agentId)) {
          candidateAgentIds.add(agentId);
        }
      }
    }

    final newestSequence = events.isEmpty ? 0 : events.last.sequence;
    final missedEventWindow =
        _conversationId == conversation.id &&
        _lastAppliedSequence > 0 &&
        events.isNotEmpty &&
        events.first.sequence > _lastAppliedSequence + 1;
    final reset =
        _conversationId != conversation.id ||
        newestSequence < _lastAppliedSequence ||
        missedEventWindow;

    var changed = false;
    if (reset) {
      final initialOrder = <String>[];
      final seenSpeakers = <String>{};
      for (final event in events.reversed) {
        if (event.kind != ConversationEventKind.message) continue;
        final agentId = membershipById[event.authorMembershipId];
        if (agentId != null && seenSpeakers.add(agentId)) {
          initialOrder.add(agentId);
        }
      }
      for (final agentId in candidateAgentIds) {
        if (seenSpeakers.add(agentId)) initialOrder.add(agentId);
      }
      changed = _queue.replaceWith(initialOrder);
    } else {
      if (!_sameIds(_candidateAgentIds, candidateAgentIds)) {
        changed = _queue.retainAndAppend(candidateAgentIds) || changed;
      }
      for (final event in events) {
        if (event.sequence <= _lastAppliedSequence ||
            event.kind != ConversationEventKind.message) {
          continue;
        }
        final agentId = membershipById[event.authorMembershipId];
        if (agentId != null) {
          changed = _queue.promote(agentId) || changed;
        }
      }
    }

    _conversationId = conversation.id;
    _lastAppliedSequence = newestSequence;
    _candidateAgentIds = List<String>.unmodifiable(candidateAgentIds);
    return changed;
  }

  bool clear() {
    final changed = _queue.clear();
    _conversationId = '';
    _lastAppliedSequence = 0;
    _candidateAgentIds = const [];
    return changed;
  }
}

bool _sameIds(List<String> left, List<String> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

final class _RecentParticipantQueue {
  final Map<String, _RecentParticipantNode> _nodes = {};
  _RecentParticipantNode? _head;
  _RecentParticipantNode? _tail;
  List<String>? _cachedSnapshot;

  bool replaceWith(Iterable<String> agentIds) {
    final previous = snapshot();
    clear();
    for (final agentId in agentIds) {
      _append(agentId);
    }
    return !_sameIds(previous, snapshot());
  }

  bool retainAndAppend(Iterable<String> agentIds) {
    final ordered = <String>[];
    final retained = <String>{};
    for (final value in agentIds) {
      final agentId = value.trim();
      if (agentId.isNotEmpty && retained.add(agentId)) ordered.add(agentId);
    }
    var changed = false;
    for (final node in List<_RecentParticipantNode>.of(_nodes.values)) {
      if (!retained.contains(node.agentId)) {
        _remove(node);
        changed = true;
      }
    }
    for (final agentId in ordered) {
      if (_append(agentId)) changed = true;
    }
    return changed;
  }

  bool promote(String value) {
    final agentId = value.trim();
    if (agentId.isEmpty) return false;
    final current = _nodes[agentId];
    if (identical(current, _head)) return false;
    final node = current ?? _RecentParticipantNode(agentId);
    if (current != null) _unlink(node);
    _nodes[agentId] = node;
    node
      ..previous = null
      ..next = _head;
    _head?.previous = node;
    _head = node;
    _tail ??= node;
    _cachedSnapshot = null;
    return true;
  }

  List<String> snapshot() {
    final cached = _cachedSnapshot;
    if (cached != null) return cached;
    final result = <String>[];
    var current = _head;
    while (current != null) {
      result.add(current.agentId);
      current = current.next;
    }
    return _cachedSnapshot = List<String>.unmodifiable(result);
  }

  bool clear() {
    if (_nodes.isEmpty) return false;
    _nodes.clear();
    _head = null;
    _tail = null;
    _cachedSnapshot = null;
    return true;
  }

  bool _append(String value) {
    final agentId = value.trim();
    if (agentId.isEmpty || _nodes.containsKey(agentId)) return false;
    final node = _RecentParticipantNode(agentId)..previous = _tail;
    _tail?.next = node;
    _tail = node;
    _head ??= node;
    _nodes[agentId] = node;
    _cachedSnapshot = null;
    return true;
  }

  void _remove(_RecentParticipantNode node) {
    _unlink(node);
    _nodes.remove(node.agentId);
    _cachedSnapshot = null;
  }

  void _unlink(_RecentParticipantNode node) {
    final previous = node.previous;
    final next = node.next;
    if (previous == null) {
      _head = next;
    } else {
      previous.next = next;
    }
    if (next == null) {
      _tail = previous;
    } else {
      next.previous = previous;
    }
    node
      ..previous = null
      ..next = null;
  }
}

final class _RecentParticipantNode {
  _RecentParticipantNode(this.agentId);

  final String agentId;
  _RecentParticipantNode? previous;
  _RecentParticipantNode? next;
}
