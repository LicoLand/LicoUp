import 'dart:collection';

import 'package:licoup/src/contracts/agent_conversation_attachment.dart';
import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/target_candidate.dart';

const int maxPendingConversationTurns = 16;

/// Immutable send intent captured at submission time. A queued turn keeps the
/// agent, native conversation, runtime settings, and transport choice that the
/// user actually submitted instead of reading mutable UI selection later.
final class ConversationQueuedTurn {
  ConversationQueuedTurn({
    required this.submissionId,
    required this.agent,
    required this.text,
    required this.session,
    required this.nativeSessionId,
    required this.workingDirectory,
    required this.model,
    required this.reasoningEffort,
    required this.throughMobileRelay,
    this.licoProfile = '',
    this.conversationOwnerAgentId = '',
    this.participantLabel = '',
    this.participantRole = '',
    this.newConversationDraftToken = '',
    this.awaitActiveSession = false,
    this.promoteToCurrentConversationOnSuccess = false,
    this.dailyQuotaFallbackAttemptedKeys = const <String>{},
    this.ideHandoffComposerId = '',
    this.allowedTools = const <String>[],
    this.scopeKey = '',
    List<ConversationAttachment> attachments = const <ConversationAttachment>[],
  }) : attachments = List<ConversationAttachment>.unmodifiable(attachments);

  final int submissionId;
  final TargetCandidate agent;
  final String text;
  final AgentConversationSession? session;
  final String nativeSessionId;
  final String workingDirectory;
  final String model;
  final String reasoningEffort;
  final bool throughMobileRelay;
  final String licoProfile;
  final String conversationOwnerAgentId;
  final String participantLabel;
  final String participantRole;
  final List<String> allowedTools;
  final String newConversationDraftToken;
  final bool awaitActiveSession;

  /// When true, a successful Lico group send persists this agent/model as
  /// Current Conversation (Daily Conversation quota fallback).
  final bool promoteToCurrentConversationOnSuccess;

  /// `(agentId\\0model)` keys already tried for Daily Conversation quota
  /// fallback so a chain does not retry the same capsule.
  final Set<String> dailyQuotaFallbackAttemptedKeys;

  /// IDE composer id for a one-time Cursor IDE→CLI handoff. On successful
  /// send, the controller marks this id so the handoff is not repeated.
  final String ideHandoffComposerId;

  /// Conversation scope the user was viewing when the turn was submitted
  /// (same identity as [AgentWorkspaceCoordinator.conversationComposerScopeKey]).
  /// The live process card renders only while the user is viewing this scope.
  final String scopeKey;

  /// Immutable ordered snapshot of the local image attachments submitted with
  /// this turn. Captured at submission time; a retry carries the same list and
  /// the path is never encoded into prompt text.
  final List<ConversationAttachment> attachments;

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
      licoProfile: licoProfile,
      conversationOwnerAgentId: conversationOwnerAgentId,
      participantLabel: participantLabel,
      participantRole: participantRole,
      newConversationDraftToken: newConversationDraftToken,
      promoteToCurrentConversationOnSuccess:
          promoteToCurrentConversationOnSuccess,
      dailyQuotaFallbackAttemptedKeys: dailyQuotaFallbackAttemptedKeys,
      ideHandoffComposerId: ideHandoffComposerId,
      scopeKey: scopeKey,
      attachments: attachments,
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
