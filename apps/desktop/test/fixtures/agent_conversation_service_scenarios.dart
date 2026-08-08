import 'agent_conversation_service/filtering_scenarios.dart';
import 'agent_conversation_service/structured_event_scenarios.dart';

export 'agent_conversation_service/dispatch_resume_scenarios.dart'
    show registerAgentConversationDispatchScenarios;
export 'agent_conversation_service/history_loading_scenarios.dart'
    show registerAgentConversationHistoryLoadingScenarios;
export 'agent_conversation_service/snapshot_scenarios.dart'
    show registerAgentConversationArchiveScenarios;

void registerAgentConversationProjectionScenarios() {
  registerAgentConversationFilteringScenarios();
  registerAgentConversationStructuredEventScenarios();
}
