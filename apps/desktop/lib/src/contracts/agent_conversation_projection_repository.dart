import 'agent_conversation_session.dart';

abstract interface class AgentConversationProjectionRepository {
  Future<Map<String, List<AgentConversationSession>>> load(Object portableData);

  Future<void> save(
    Object portableData,
    Map<String, List<AgentConversationSession>> sessionsByAgent,
  );
}
