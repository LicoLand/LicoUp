import 'package:licoup/src/application/features/agents/conversation/agent_conversation_controller.dart';
import 'package:licoup/src/application/features/agents/orchestration/agent_orchestration_presentation.dart';

/// Main-agent conversation with locally provided subordinate-agent tools.
abstract class AgentOrchestrationController extends AgentConversationController
    with AgentOrchestrationPresentation {}
