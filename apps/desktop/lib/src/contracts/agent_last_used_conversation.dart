/// One persisted reference to the conversation the user last worked in:
/// the conversation agent plus the session that was open when the client
/// closed. Restored on relaunch so the client reopens the same conversation
/// instead of landing on the new-conversation home.
final class LastUsedConversationRef {
  const LastUsedConversationRef({
    required this.agentId,
    required this.sessionId,
  });

  /// Agent id for the selected conversation.
  /// Empty when nothing has been recorded yet.
  final String agentId;

  /// Open session id for [agentId]; empty when the last state was the
  /// agent's new-conversation home.
  final String sessionId;

  bool get isEmpty => agentId.trim().isEmpty;
}

/// Local persistence for the last-used conversation reference.
abstract interface class LastUsedConversationStore {
  Future<LastUsedConversationRef?> load(Object portableData);

  Future<void> save(Object portableData, LastUsedConversationRef ref);
}
