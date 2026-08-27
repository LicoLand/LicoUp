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
    required this.messageUnit,
  });

  /// Stable blackboard slot key (`agentId\0role`) of this reply.
  final String key;
  final String text;
  final String createdAt;
  final String participantAgentId;
  final String participantLabel;
  final String participantRole;
  final String messageUnit;
}

final class _ConversationReply {
  _ConversationReply({required this.text, required this.createdAt});

  String text;
  String createdAt;
  String participantAgentId = '';
  String participantLabel = '';
  String participantRole = '';
  String messageUnit = '';
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
  final List<String> _observedStages = [];
  final List<AgentConversationMessage> _evidence = [];
  final Map<String, _ConversationReply> _repliesByParticipant =
      <String, _ConversationReply>{};
  String _participantAgentId = '';
  String _participantLabel = '';
  String _participantRole = '';
  AgentConversationMessage? _runtimeUpdate;

  List<AgentConversationMessage>? _projectedWithUser;
  List<AgentConversationMessage>? _projectedWithoutUser;
  int _projectionRevision = 0;
  int _projectedWithUserRevision = -1;
  int _projectedWithoutUserRevision = -1;

  /// Slot-level message caches. The projection must return identical message
  /// objects for slots whose content did not change, otherwise the timeline
  /// tail-swap fast path (which compares item identity) can never engage and
  /// every streamed chunk rebuilds the whole list.
  AgentConversationMessage? _userMessage;
  AgentConversationMessage? _lifecycleMessage;
  String _lifecycleMessageKey = '';
  final Map<String, AgentConversationMessage> _replyMessages = {};

  /// Monotonic revision incremented on every blackboard mutation. The group
  /// pane uses it to keep the outer live-message list identity stable while
  /// chunks arrive, so the message-list timeline cache keeps its fast path.
  int get projectionRevision => _projectionRevision;

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

  String replyTextFor(String participantKey) =>
      _repliesByParticipant[participantKey]?.text ?? '';

  String get replyCreatedAt =>
      _repliesByParticipant[_primaryReplyKey]?.createdAt ?? '';

  AgentConversationMessage? get runtimeUpdate => _runtimeUpdate;

  String get participantAgentId => _participantAgentId;

  String get participantLabel => _participantLabel;

  String get participantRole => _participantRole;

  /// Live timeline projection of this blackboard. Group observers omit the
  /// user message because Canonical Conversation already owns that Event.
  ///
  /// Each projection variant is memoized at its own revision: a streamed chunk
  /// re-derives exactly once per blackboard mutation, while a publish without
  /// content change reuses the identical message list so the timeline cache
  /// keeps its in-place fast path.
  List<AgentConversationMessage> projectedMessages({bool includeUser = true}) {
    if (includeUser) {
      final cached = _projectedWithUser;
      if (cached != null && _projectedWithUserRevision == _projectionRevision) {
        return cached;
      }
      final projected = List<AgentConversationMessage>.unmodifiable(
        _buildProjectedMessages(includeUser: true),
      );
      _projectedWithUser = projected;
      _projectedWithUserRevision = _projectionRevision;
      return projected;
    }
    final cached = _projectedWithoutUser;
    if (cached != null &&
        _projectedWithoutUserRevision == _projectionRevision) {
      return cached;
    }
    final projected = List<AgentConversationMessage>.unmodifiable(
      _buildProjectedMessages(includeUser: false),
    );
    _projectedWithoutUser = projected;
    _projectedWithoutUserRevision = _projectionRevision;
    return projected;
  }

  List<AgentConversationMessage> _buildProjectedMessages({
    required bool includeUser,
  }) {
    final messages = <AgentConversationMessage>[
      if (includeUser) _userMessageFor(),
      if (_observedStages.isNotEmpty ||
          _stage == ConversationTurnProcessStage.failed)
        _lifecycleMessageFor(),
    ];
    final update = _runtimeUpdate;
    if (update != null) {
      messages.add(update);
    }
    messages.addAll(_evidence);
    for (final reply in replies) {
      messages.add(_replyMessageFor(reply));
    }
    return messages;
  }

  AgentConversationMessage _userMessageFor() {
    return _userMessage ??= AgentConversationMessage(
      id: '$turnId-user',
      role: 'user',
      text: userText,
      createdAt: _createdAt,
      stableIdentity: '$turnId-user',
    );
  }

  AgentConversationMessage _lifecycleMessageFor() {
    final key = [
      _stage.id,
      _observedStages.join(','),
      _participantAgentId,
      _participantLabel,
      _participantRole,
    ].join('\u0001');
    final cached = _lifecycleMessage;
    if (cached != null && _lifecycleMessageKey == key) return cached;
    final message = AgentConversationMessage(
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
    );
    _lifecycleMessage = message;
    _lifecycleMessageKey = key;
    return message;
  }

  AgentConversationMessage _replyMessageFor(
    ConversationParticipantReply reply,
  ) {
    final primary = isPrimaryReplyKey(reply.key);
    final participantIdentityBase = primary
        ? '$turnId-assistant'
        : '$turnId-assistant-${reply.participantAgentId.trim()}-${reply.participantRole.trim()}';
    final participantIdentity = reply.messageUnit.isEmpty
        ? participantIdentityBase
        : '$participantIdentityBase-message-${reply.messageUnit}';
    final cached = _replyMessages[reply.key];
    if (cached != null &&
        cached.text == reply.text &&
        cached.createdAt ==
            (reply.createdAt.isEmpty ? _createdAt : reply.createdAt) &&
        cached.participantAgentId == reply.participantAgentId &&
        cached.participantLabel == reply.participantLabel &&
        cached.participantRole == reply.participantRole) {
      return cached;
    }
    final message = AgentConversationMessage(
      id: participantIdentity,
      role: 'assistant',
      text: reply.text,
      createdAt: reply.createdAt.isEmpty ? _createdAt : reply.createdAt,
      stableIdentity: participantIdentity,
      participantAgentId: reply.participantAgentId,
      participantLabel: reply.participantLabel,
      participantRole: reply.participantRole,
    );
    _replyMessages[reply.key] = message;
    return message;
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
    String messageUnit = '',
  }) {
    final agentId = participantAgentId.trim();
    final role = participantRole.trim();
    if (turnId == this.turnId) {
      // The turn's own participant (main agent).
      final resolvedAgentId = agentId.isNotEmpty
          ? agentId
          : _participantAgentId.trim();
      final resolvedRole = role.isNotEmpty ? role : _participantRole.trim();
      if (resolvedAgentId.isEmpty && resolvedRole.isEmpty) {
        return messageUnit.isEmpty ? '' : '\u0000\u0000$messageUnit';
      }
      final base = '$resolvedAgentId\u0000$resolvedRole';
      return messageUnit.isEmpty ? base : '$base\u0000$messageUnit';
    }
    final participantPrefix = '${this.turnId}-participant-';
    if (turnId.startsWith(participantPrefix)) {
      // Orchestration stream peer reply: `-participant-<agentId>`.
      final id = turnId.substring(participantPrefix.length).trim();
      if (id.isEmpty) return null;
      final base = '$id\u0000${role.isNotEmpty ? role : 'peer-agent'}';
      return messageUnit.isEmpty ? base : '$base\u0000$messageUnit';
    }
    final handoffPrefix = '${this.turnId}-handoff-';
    if (turnId.startsWith(handoffPrefix)) {
      // LicoUp-owned subagent handoff bubble projected onto this turn.
      if (agentId.isEmpty) return null;
      final base = '$agentId\u0000${role.isNotEmpty ? role : 'peer-agent'}';
      return messageUnit.isEmpty ? base : '$base\u0000$messageUnit';
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
    messageUnit: reply.messageUnit,
  );

  /// Render one Rust-owned lifecycle transition. Regressions are no-ops and
  /// `failed` is terminal; Flutter never invents missing predecessor stages.
  void advanceStage(String stage) {
    if (_stage == ConversationTurnProcessStage.failed) return;
    if (stage.trim().toLowerCase() == ConversationTurnProcessStage.failed.id) {
      _stage = ConversationTurnProcessStage.failed;
      _markProjectionDirty();
      return;
    }
    final next = ConversationTurnProcessStage.of(stage);
    if (next == null || next.index < _stage.index) return;
    final changed = _recordObservedStage(next);
    _stage = next;
    if (changed) _markProjectionDirty();
  }

  void recordParticipant({
    String participantAgentId = '',
    String participantLabel = '',
    String participantRole = '',
    String messageUnit = '',
  }) {
    var changed = false;
    if (participantAgentId.isNotEmpty &&
        participantAgentId != _participantAgentId) {
      _participantAgentId = participantAgentId;
      changed = true;
    }
    if (participantLabel.isNotEmpty && participantLabel != _participantLabel) {
      _participantLabel = participantLabel;
      changed = true;
    }
    if (participantRole.isNotEmpty && participantRole != _participantRole) {
      _participantRole = participantRole;
      changed = true;
    }
    if (changed) _markProjectionDirty();
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
    _markProjectionDirty();
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
    String messageUnit = '',
  }) {
    final key = participantKey.isEmpty ? _primaryReplyKey : participantKey;
    final existing = _repliesByParticipant[key];
    if (existing != null) {
      final textChanged = existing.text != text;
      final createdAtChanged =
          text.trim().isNotEmpty && existing.createdAt.isEmpty;
      existing.text = text;
      existing.messageUnit = messageUnit;
      if (createdAtChanged) {
        existing.createdAt = createdAt;
      }
      if (textChanged || createdAtChanged) _markProjectionDirty();
      return;
    }
    _repliesByParticipant[key] =
        _ConversationReply(
            text: text,
            createdAt: text.trim().isNotEmpty ? createdAt : '',
          )
          ..participantAgentId = participantAgentId
          ..participantLabel = participantLabel
          ..participantRole = participantRole
          ..messageUnit = messageUnit;
    _markProjectionDirty();
  }

  /// The in-place runtime-update card (for example cursor-agent auto-update
  /// blocking the turn). It is a separate card from the process blackboard
  /// and must survive re-projection.
  void setRuntimeUpdate(AgentConversationMessage message) {
    _runtimeUpdate = message;
    _markProjectionDirty();
  }

  void _markProjectionDirty() {
    _projectionRevision += 1;
  }

  bool _recordObservedStage(ConversationTurnProcessStage stage) {
    if (_observedStages.contains(stage.id)) {
      return false;
    }
    _observedStages.add(stage.id);
    return true;
  }
}
