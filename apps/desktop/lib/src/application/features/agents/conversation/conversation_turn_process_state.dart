import 'package:licoup/src/contracts/agent_conversation_models.dart';

/// Ordered lifecycle stages of an in-flight turn. `failed` is terminal: once
/// reached, no later event may move the card again.
enum ConversationTurnProcessStage {
  submitted('submitted'),
  accepted('accepted'),
  processing('processing'),
  responding('responding'),
  completed('completed'),
  failed('failed');

  const ConversationTurnProcessStage(this.id);

  final String id;

  static ConversationTurnProcessStage? of(String stage) {
    for (final candidate in values) {
      if (candidate.id == stage.trim().toLowerCase()) return candidate;
    }
    return null;
  }
}

/// One streamed participant reply on the turn blackboard. The turn's own
/// participant (main agent) is projected first; peer replies (orchestration
/// participant streams, subagent handoff bubbles) follow in arrival order.
final class ConversationParticipantReply {
  const ConversationParticipantReply({
    required this.key,
    required this.text,
    required this.createdAt,
    required this.participantAgentId,
    required this.participantLabel,
    required this.participantRole,
  });

  /// Stable blackboard slot key (`agentId\0role`) of this reply.
  final String key;
  final String text;
  final String createdAt;
  final String participantAgentId;
  final String participantLabel;
  final String participantRole;
}

final class _ConversationReply {
  _ConversationReply({required this.text, required this.createdAt});

  String text;
  String createdAt;
  String participantAgentId = '';
  String participantLabel = '';
  String participantRole = '';
}

/// The blackboard for one in-flight turn.
///
/// The card is bound to [turnId] from the moment the user sends the message
/// and never changes identity while the turn runs. Incoming stream events only
/// push this state machine forward; the live message projection (and the
/// frontend card) are derived from the state, so the card stays pinned on the
/// interface and only its content advances.
final class ConversationTurnProcessState {
  ConversationTurnProcessState({
    required this.turnId,
    required this.userText,
    required String createdAt,
    this.scopeKey = '',
  }) : _createdAt = createdAt;

  final String turnId;
  final String userText;
  final String _createdAt;

  /// Conversation scope this turn belongs to (same identity as
  /// `conversationComposerScopeKey`). The live process card is only rendered
  /// while the user is viewing this scope; other conversations never show a
  /// turn that does not belong to them.
  final String scopeKey;

  ConversationTurnProcessStage _stage = ConversationTurnProcessStage.submitted;
  final List<String> _observedStages = [
    ConversationTurnProcessStage.submitted.id,
  ];
  final List<AgentConversationMessage> _evidence = [];
  final Map<String, _ConversationReply> _repliesByParticipant =
      <String, _ConversationReply>{};
  String _participantAgentId = '';
  String _participantLabel = '';
  String _participantRole = '';
  AgentConversationMessage? _runtimeUpdate;

  ConversationTurnProcessStage get stage => _stage;

  String get createdAt => _createdAt;

  /// Observed lifecycle stages in canonical order, deduplicated.
  List<String> get observedStages => List<String>.unmodifiable(_observedStages);

  /// Evidence operations (reasoning / tool calls / tool results) in arrival
  /// order. Consecutive entries of the same kind collapse into one step: the
  /// stream repeats `reasoning` or `tool` deltas many times per turn, and
  /// repeated identical deltas are one blackboard step, not new operations.
  List<AgentConversationMessage> get evidence =>
      List<AgentConversationMessage>.unmodifiable(_evidence);

  String get replyText => _repliesByParticipant[_primaryReplyKey]?.text ?? '';

  String get replyCreatedAt =>
      _repliesByParticipant[_primaryReplyKey]?.createdAt ?? '';

  AgentConversationMessage? get runtimeUpdate => _runtimeUpdate;

  String get participantAgentId => _participantAgentId;

  String get participantLabel => _participantLabel;

  String get participantRole => _participantRole;

  /// Live timeline projection of this blackboard. Group observers omit the
  /// user message because Canonical Conversation already owns that Event.
  List<AgentConversationMessage> projectedMessages({bool includeUser = true}) {
    final messages = <AgentConversationMessage>[
      if (includeUser)
        AgentConversationMessage(
          id: '$turnId-user',
          role: 'user',
          text: userText,
          createdAt: _createdAt,
          stableIdentity: '$turnId-user',
        ),
      AgentConversationMessage(
        id: '$turnId-lifecycle',
        role: _stage == ConversationTurnProcessStage.failed ? 'error' : 'event',
        text: _stage.id,
        createdAt: _createdAt,
        layer: AgentConversationSemanticLayer.execution,
        cardType: 'lifecycle',
        cardTitle: 'lifecycle.${_stage.id}',
        cardSubtitle: _observedStages.join(','),
        stableIdentity: '$turnId-lifecycle',
        participantAgentId: _participantAgentId,
        participantLabel: _participantLabel,
        participantRole: _participantRole,
      ),
    ];
    final update = _runtimeUpdate;
    if (update != null) {
      messages.add(update);
    }
    messages.addAll(_evidence);
    for (final reply in replies) {
      final primary = isPrimaryReplyKey(reply.key);
      final participantIdentity = primary
          ? '$turnId-assistant'
          : '$turnId-assistant-${reply.participantAgentId.trim()}-${reply.participantRole.trim()}';
      messages.add(
        AgentConversationMessage(
          id: participantIdentity,
          role: 'assistant',
          text: reply.text,
          createdAt: reply.createdAt.isEmpty ? _createdAt : reply.createdAt,
          stableIdentity: participantIdentity,
          participantAgentId: reply.participantAgentId,
          participantLabel: reply.participantLabel,
          participantRole: reply.participantRole,
        ),
      );
    }
    return List<AgentConversationMessage>.unmodifiable(messages);
  }

  /// The blackboard slot of the turn's own participant. The lifecycle card
  /// records the participant before any reply lands, so a main-agent reply
  /// shares the recorded identity; with no participant recorded the legacy
  /// single-reply slot (empty key) is the primary.
  String get _primaryReplyKey {
    final id = _participantAgentId.trim();
    final role = _participantRole.trim();
    return id.isEmpty && role.isEmpty ? '' : '$id\u0000$role';
  }

  bool isPrimaryReplyKey(String key) => key == _primaryReplyKey;

  /// Maps an incoming reply [turnId] to the blackboard slot it belongs to, or
  /// null when the turn id belongs to a different (usually replaced) turn.
  ///
  /// The card is bound to this turn's [turnId], so the strict equality guard
  /// of the projection controller must accept the derived ids of the same
  /// turn: `-participant-<agentId>` suffixes for orchestration peer replies
  /// and `-handoff-<dispatchId>` suffixes for LicoUp-owned handoff bubbles.
  /// Stale events of an older turn (whose ids derive from a different turn id)
  /// never match and are dropped instead of corrupting the current card.
  String? participantReplyKey({
    required String turnId,
    required String participantAgentId,
    required String participantRole,
  }) {
    final agentId = participantAgentId.trim();
    final role = participantRole.trim();
    if (turnId == this.turnId) {
      // The turn's own participant (main agent).
      final resolvedAgentId = agentId.isNotEmpty
          ? agentId
          : _participantAgentId.trim();
      final resolvedRole = role.isNotEmpty ? role : _participantRole.trim();
      if (resolvedAgentId.isEmpty && resolvedRole.isEmpty) return '';
      return '$resolvedAgentId\u0000$resolvedRole';
    }
    final participantPrefix = '${this.turnId}-participant-';
    if (turnId.startsWith(participantPrefix)) {
      // Orchestration stream peer reply: `-participant-<agentId>`.
      final id = turnId.substring(participantPrefix.length).trim();
      if (id.isEmpty) return null;
      return '$id\u0000${role.isNotEmpty ? role : 'peer-agent'}';
    }
    final handoffPrefix = '${this.turnId}-handoff-';
    if (turnId.startsWith(handoffPrefix)) {
      // LicoUp-owned subagent handoff bubble projected onto this turn.
      if (agentId.isEmpty) return null;
      return '$agentId\u0000${role.isNotEmpty ? role : 'peer-agent'}';
    }
    return null;
  }

  /// Streamed replies in presentation order: the turn's own participant
  /// first, then peer replies in arrival order. Empty replies are skipped.
  List<ConversationParticipantReply> get replies {
    final primaryKey = _primaryReplyKey;
    final result = <ConversationParticipantReply>[];
    final primary = _repliesByParticipant[primaryKey];
    if (primary != null && primary.text.trim().isNotEmpty) {
      result.add(_viewReply(primaryKey, primary));
    }
    for (final entry in _repliesByParticipant.entries) {
      if (entry.key == primaryKey || entry.value.text.trim().isEmpty) continue;
      result.add(_viewReply(entry.key, entry.value));
    }
    return result;
  }

  ConversationParticipantReply _viewReply(
    String key,
    _ConversationReply reply,
  ) => ConversationParticipantReply(
    key: key,
    text: reply.text,
    createdAt: reply.createdAt,
    participantAgentId: reply.participantAgentId,
    participantLabel: reply.participantLabel,
    participantRole: reply.participantRole,
  );

  /// Advance to a later lifecycle stage. Regressions are no-ops; `failed` is
  /// terminal and locks the card. A later stage proves that every earlier
  /// stage was crossed even when the transport coalesces their events, so the
  /// observed prefix is filled monotonically instead of leaving visual holes.
  void advanceStage(String stage) {
    if (_stage == ConversationTurnProcessStage.failed) return;
    if (stage.trim().toLowerCase() == ConversationTurnProcessStage.failed.id) {
      _stage = ConversationTurnProcessStage.failed;
      return;
    }
    final next = ConversationTurnProcessStage.of(stage);
    if (next == null || next.index <= _stage.index) return;
    for (var index = _stage.index + 1; index <= next.index; index++) {
      _recordObservedStage(ConversationTurnProcessStage.values[index]);
    }
    _stage = next;
  }

  void recordParticipant({
    String participantAgentId = '',
    String participantLabel = '',
    String participantRole = '',
  }) {
    if (participantAgentId.isNotEmpty) _participantAgentId = participantAgentId;
    if (participantLabel.isNotEmpty) _participantLabel = participantLabel;
    if (participantRole.isNotEmpty) _participantRole = participantRole;
  }

  /// Append one evidence operation. Consecutive entries with the same message
  /// kind AND the same content collapse into a single blackboard step (the
  /// stream repeats identical `reasoning`/`tool` deltas many times per turn);
  /// a different tool or a different kind of work is a new step.
  void appendEvidence(AgentConversationMessage message) {
    final last = _evidence.isNotEmpty ? _evidence.last : null;
    if (last != null &&
        last.kind == message.kind &&
        last.text == message.text) {
      return;
    }
    _evidence.add(message);
  }

  /// Update one participant reply in place. [participantKey] is the blackboard
  /// slot resolved by [participantReplyKey]; without one the reply lands on
  /// the primary slot so the legacy single-reply callers keep working.
  void setReplyText(
    String text, {
    required String createdAt,
    String participantKey = '',
    String participantAgentId = '',
    String participantLabel = '',
    String participantRole = '',
  }) {
    final key = participantKey.isEmpty ? _primaryReplyKey : participantKey;
    final existing = _repliesByParticipant[key];
    if (existing != null) {
      existing.text = text;
      if (text.trim().isNotEmpty && existing.createdAt.isEmpty) {
        existing.createdAt = createdAt;
      }
      return;
    }
    _repliesByParticipant[key] =
        _ConversationReply(
            text: text,
            createdAt: text.trim().isNotEmpty ? createdAt : '',
          )
          ..participantAgentId = participantAgentId
          ..participantLabel = participantLabel
          ..participantRole = participantRole;
  }

  /// The in-place runtime-update card (for example cursor-agent auto-update
  /// blocking the turn). It is a separate card from the process blackboard
  /// and must survive re-projection.
  void setRuntimeUpdate(AgentConversationMessage message) {
    _runtimeUpdate = message;
  }

  void _recordObservedStage(ConversationTurnProcessStage stage) {
    if (!_observedStages.contains(stage.id)) {
      _observedStages.add(stage.id);
    }
  }
}
