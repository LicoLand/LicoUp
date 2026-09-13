/// Exact local execution identity. Native catalog session IDs are unrelated.
final class ConversationExecutionReference {
  const ConversationExecutionReference({
    required this.conversationId,
    required this.membershipId,
    required this.turnHandle,
  });
  final String conversationId;
  final String membershipId;
  final String turnHandle;

  static ConversationExecutionReference? fromJson(Object? value) {
    if (value is! Map) {
      return null;
    }
    final conversation = value['conversationId'];
    final membership = value['membershipId'];
    final handle = value['turnHandle'];
    if (conversation is! String ||
        conversation.isEmpty ||
        membership is! String ||
        membership.isEmpty ||
        handle is! String ||
        handle.isEmpty) {
      return null;
    }
    return ConversationExecutionReference(
      conversationId: conversation,
      membershipId: membership,
      turnHandle: handle,
    );
  }

  Map<String, dynamic> toJson() => {
    'conversationId': conversationId,
    'membershipId': membershipId,
    'turnHandle': turnHandle,
  };
  @override
  bool operator ==(Object other) =>
      other is ConversationExecutionReference &&
      other.conversationId == conversationId &&
      other.membershipId == membershipId &&
      other.turnHandle == turnHandle;
  @override
  int get hashCode => Object.hash(conversationId, membershipId, turnHandle);
}

/// Original native payload. The text must never be normalized or re-encoded.
final class ConversationExecutionRecord {
  const ConversationExecutionRecord({
    required this.id,
    required this.rawText,
    this.kind = '',
    this.timestamp = '',
    this.cursor = 0,
  });
  final String id;
  final String rawText;
  final String kind;
  final String timestamp;
  final int cursor;
}

sealed class ConversationExecutionEvent {
  const ConversationExecutionEvent();
}

final class ConversationExecutionRecordEvent
    extends ConversationExecutionEvent {
  const ConversationExecutionRecordEvent(this.record);
  final ConversationExecutionRecord record;
}

final class ConversationExecutionReady extends ConversationExecutionEvent {
  const ConversationExecutionReady({
    required this.reference,
    required this.cursor,
    required this.status,
    required this.observationAvailable,
    required this.terminalPayloadAvailable,
  });
  final ConversationExecutionReference reference;
  final int cursor;
  final String status;
  final bool observationAvailable;
  final bool terminalPayloadAvailable;
}

final class ConversationExecutionState {
  const ConversationExecutionState({
    this.records = const [],
    this.loading = true,
    this.errorCode = '',
    this.status = '',
    this.observationAvailable = false,
    this.terminalPayloadAvailable = false,
  });
  final List<ConversationExecutionRecord> records;
  final bool loading;
  final String errorCode;
  final String status;
  final bool observationAvailable;
  final bool terminalPayloadAvailable;
  bool get terminal => const {
    'completed',
    'failed',
    'cancelled',
    'interrupted',
  }.contains(status);
}
