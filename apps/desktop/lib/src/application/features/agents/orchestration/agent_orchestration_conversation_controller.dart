import 'package:licoup/src/application/features/agents/workspace/agent_workspace_coordinator.dart';
import 'package:licoup/src/platform/native_client/orchestrator_ipc/client.dart';

/// Holds only the latest immutable backend projection for rendering.
mixin AgentOrchestrationConversationController on AgentWorkspaceCoordinator {
  int _submissionSequence = 0;

  String nextOrchestrationSubmissionId() {
    _submissionSequence = (_submissionSequence + 1) & 0x7fffffff;
    return 'desktop-submit-$_submissionSequence';
  }

  void projectOrchestrationWorkflow(OrchestratorWorkflowProjection projection) {
    final current = currentOrchestrationProjection;
    if (current != null &&
        current.workflowId == projection.workflowId &&
        projection.sequence <= current.sequence) {
      return;
    }
    currentOrchestrationProjection = projection;
    statusCaption = 'Agent orchestration';
    agentWorkspaceSetLocalizedStatusMessage(
      '编排状态：${projection.state}',
      'Orchestration state: ${projection.state}',
    );
    agentWorkspaceNotifyStateChanged();
  }
}
