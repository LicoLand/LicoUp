import 'dart:collection';

import 'package:flutter_client/src/contracts/agent_conversation_models.dart';
import 'package:flutter_client/src/contracts/target_candidate.dart';

const int maxPendingConversationTurns = 16;

/// Immutable send intent captured at submission time. A queued turn keeps the
/// agent, native conversation, runtime settings, and transport choice that the
/// user actually submitted instead of reading mutable UI selection later.
final class ConversationQueuedTurn {
  const ConversationQueuedTurn({
    required this.submissionId,
    required this.agent,
    required this.text,
    required this.session,
    required this.nativeSessionId,
    required this.workingDirectory,
    required this.model,
    required this.reasoningEffort,
    required this.throughMobileRelay,
    this.newConversationDraftToken = '',
    this.orchestration = false,
    this.awaitActiveSession = false,
  });

  final int submissionId;
  final TargetCandidate agent;
  final String text;
  final AgentConversationSession? session;
  final String nativeSessionId;
  final String workingDirectory;
  final String model;
  final String reasoningEffort;
  final bool throughMobileRelay;
  final String newConversationDraftToken;
  final bool orchestration;
  final bool awaitActiveSession;

  ConversationQueuedTurn bindActiveSession(String sessionId) {
    final normalized = sessionId.trim();
    if (!awaitActiveSession || normalized.isEmpty) return this;
    return ConversationQueuedTurn(
      submissionId: submissionId,
      agent: agent,
      text: text,
      session: session,
      nativeSessionId: normalized,
      workingDirectory: workingDirectory,
      model: model,
      reasoningEffort: reasoningEffort,
      throughMobileRelay: throughMobileRelay,
      newConversationDraftToken: newConversationDraftToken,
      orchestration: orchestration,
    );
  }
}

enum ConversationTurnEnqueueResult { accepted, full, duplicate }

/// Bounded FIFO for user-submitted follow-up turns. Submission identifiers are
/// retained while pending so a completion callback cannot enqueue the same
/// intent twice.
final class ConversationTurnQueue {
  ConversationTurnQueue({this.capacity = maxPendingConversationTurns})
    : assert(capacity > 0);

  final int capacity;
  final ListQueue<ConversationQueuedTurn> _pending = ListQueue();
  final Set<int> _pendingSubmissionIds = <int>{};

  int get length => _pending.length;
  bool get isEmpty => _pending.isEmpty;

  ConversationTurnEnqueueResult add(ConversationQueuedTurn turn) {
    if (_pendingSubmissionIds.contains(turn.submissionId)) {
      return ConversationTurnEnqueueResult.duplicate;
    }
    if (_pending.length >= capacity) {
      return ConversationTurnEnqueueResult.full;
    }
    _pending.addLast(turn);
    _pendingSubmissionIds.add(turn.submissionId);
    return ConversationTurnEnqueueResult.accepted;
  }

  ConversationQueuedTurn? removeFirst() {
    if (_pending.isEmpty) return null;
    final turn = _pending.removeFirst();
    _pendingSubmissionIds.remove(turn.submissionId);
    return turn;
  }

  void bindAwaitingSession({
    required String agentId,
    required String nativeSessionId,
  }) {
    final normalizedAgent = agentId.trim();
    final normalizedSession = nativeSessionId.trim();
    if (normalizedAgent.isEmpty || normalizedSession.isEmpty) return;
    final rebound = ListQueue<ConversationQueuedTurn>();
    for (final turn in _pending) {
      rebound.addLast(
        turn.agent.target == normalizedAgent
            ? turn.bindActiveSession(normalizedSession)
            : turn,
      );
    }
    _pending
      ..clear()
      ..addAll(rebound);
  }

  void clear() {
    _pending.clear();
    _pendingSubmissionIds.clear();
  }
}
