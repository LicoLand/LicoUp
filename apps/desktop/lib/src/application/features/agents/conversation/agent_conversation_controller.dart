import 'package:licoup/src/application/features/agents/conversation/conversation_live_projection_controller.dart';
import 'package:licoup/src/application/features/agents/conversation/conversation_message_controller.dart';
import 'package:licoup/src/application/features/agents/conversation/conversation_mobile_session_controller.dart';
import 'package:licoup/src/application/features/agents/conversation/conversation_relay_projection_controller.dart';
import 'package:licoup/src/application/features/agents/conversation/conversation_session_controller.dart';
import 'package:licoup/src/application/features/agents/conversation/conversation_session_state_controller.dart';
import 'package:licoup/src/application/features/agents/orchestration/agent_orchestration_policy_controller.dart';
import 'package:licoup/src/application/features/agents/workspace/agent_workspace_coordinator.dart';

export 'package:licoup/src/application/features/agents/conversation/conversation_session_state_controller.dart'
    show
        conversationSessionLoadFailedSelectionId,
        conversationSessionReadbackPendingSelectionId;
export 'package:licoup/src/application/features/agents/policy/conversation_session_index.dart'
    show secureAgentRelayNativeSessionId, secureAgentRelayReplyText;

/// Minimal composition boundary for native conversation responsibilities.
/// Each mixin below owns one independently testable lifecycle concern.
abstract class AgentConversationController extends AgentWorkspaceCoordinator
    with
        AgentConversationSessionStateController,
        AgentConversationMobileSessionController,
        AgentOrchestrationPolicyController,
        AgentConversationSessionController,
        AgentConversationLiveProjectionController,
        AgentConversationRelayProjectionController,
        AgentConversationMessageController {}
