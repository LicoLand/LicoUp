import 'package:licoup/src/application/features/agents/conversation/conversation_live_projection_controller.dart';
import 'package:licoup/src/application/features/agents/conversation/conversation_message_controller.dart';
import 'package:licoup/src/application/features/agents/conversation/conversation_session_controller.dart';
import 'package:licoup/src/application/features/agents/conversation/conversation_session_state_controller.dart';
import 'package:licoup/src/application/features/agents/workspace/agent_workspace_coordinator.dart';

export 'package:licoup/src/application/features/agents/conversation/conversation_session_state_controller.dart'
    show
        conversationSessionLoadFailedSelectionId,
        conversationSessionReadbackPendingSelectionId;

/// Minimal composition boundary for native conversation responsibilities.
/// Each mixin below owns one independently testable lifecycle concern.
abstract class AgentConversationController extends AgentWorkspaceCoordinator
    with
        AgentConversationLiveProjectionController,
        AgentConversationSessionStateController,
        AgentConversationSessionController,
        AgentConversationMessageController {
  @override
  void dispose() {
    disposeConversationLiveProjection();
    conversationStateHolder.dispose();
    super.dispose();
  }
}
