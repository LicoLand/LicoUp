import 'package:flutter_client/src/application/features/agents/conversation/agent_conversation_controller.dart';
import 'package:flutter_client/src/application/features/agents/orchestration/agent_orchestration_conversation_controller.dart';
import 'package:flutter_client/src/application/features/agents/orchestration/agent_orchestration_dispatch_controller.dart';
import 'package:flutter_client/src/application/features/agents/orchestration/agent_orchestration_presentation.dart';

/// Minimal composition boundary for optional multi-agent orchestration.
abstract class AgentOrchestrationController extends AgentConversationController
    with
        AgentOrchestrationPresentation,
        AgentOrchestrationConversationController,
        AgentOrchestrationDispatchController {}