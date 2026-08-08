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
  }) : _createdAt = createdAt;

  final String turnId;
  final String userText;
  final String _createdAt;

  ConversationTurnProcessStage _stage = ConversationTurnProcessStage.submitted;
  final List<String> _observedStages = [
    ConversationTurnProcessStage.submitted.id,
  ];
  final List<AgentConversationMessage> _evidence = [];
  String _replyText = '';
  String _replyCreatedAt = '';
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

  String get replyText => _replyText;

  String get replyCreatedAt => _replyCreatedAt;

  AgentConversationMessage? get runtimeUpdate => _runtimeUpdate;

  String get participantAgentId => _participantAgentId;

  String get participantLabel => _participantLabel;

  String get participantRole => _participantRole;

  /// Advance to a later lifecycle stage. Regressions are no-ops; `failed` is
  /// terminal and locks the card.
  void advanceStage(String stage) {
    if (_stage == ConversationTurnProcessStage.failed) return;
    if (stage.trim().toLowerCase() == ConversationTurnProcessStage.failed.id) {
      _stage = ConversationTurnProcessStage.failed;
      _recordObservedStage(ConversationTurnProcessStage.failed);
      return;
    }
    final next = ConversationTurnProcessStage.of(stage);
    if (next == null || next.index <= _stage.index) return;
    _stage = next;
    _recordObservedStage(next);
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

  void setReplyText(String text, {required String createdAt}) {
    _replyText = text;
    if (text.trim().isNotEmpty && _replyCreatedAt.isEmpty) {
      _replyCreatedAt = createdAt;
    }
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
