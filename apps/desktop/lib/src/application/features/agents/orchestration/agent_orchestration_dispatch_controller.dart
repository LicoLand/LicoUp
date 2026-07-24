import 'package:licoup/src/application/features/agents/orchestration/agent_orchestration_conversation_controller.dart';
import 'package:licoup/src/application/features/agents/orchestration/agent_orchestration_policy_controller.dart';
import 'package:licoup/src/application/features/agents/workspace/agent_workspace_coordinator.dart';
import 'package:licoup/src/contracts/agent_conversation_tab_activity.dart';
import 'package:licoup/src/contracts/agent_orchestration_target.dart';
import 'package:licoup/src/platform/native_client/orchestrator_ipc/client.dart';

/// Submits commands and projects backend-owned workflow state. This controller
/// never chooses an adapter, advances a step, or owns a native agent session.
mixin AgentOrchestrationDispatchController
    on
        AgentWorkspaceCoordinator,
        AgentOrchestrationPolicyController,
        AgentOrchestrationConversationController {
  @override
  Future<void> sendOrchestratedConversationMessage(String text) async {
    if (!orchestrationPolicyConfigured) {
      lastError = 'policy_revision_unavailable';
      agentWorkspaceSetLocalizedStatusMessage(
        '请先注册并激活编排策略。',
        'Register and activate an orchestration policy first.',
      );
      agentWorkspaceNotifyStateChanged();
      return;
    }

    isSendingConversationMessage = true;
    lastError = '';
    statusCaption = 'Agent orchestration';
    agentWorkspaceNotifyStateChanged();
    try {
      final submissionId = nextOrchestrationSubmissionId();
      final projection = await orchestratorClient.submit(
        intent: const {'kind': 'conversation'},
        policyRevision: activeOrchestrationPolicyRevision,
        idempotencyKey: submissionId,
      );
      projectOrchestrationWorkflow(projection);
      await for (final update in orchestratorClient.subscribe(
        workflowId: projection.workflowId,
        afterSequence: projection.sequence,
      )) {
        projectOrchestrationWorkflow(update);
      }
      recordConversationTabSendOutcome(
        agentId: agentOrchestrationTargetId,
        ok: currentOrchestrationProjection?.state == 'completed',
        failureCode: currentOrchestrationProjection?.state ?? '',
      );
    } on OrchestratorClientException catch (error) {
      lastError = error.code;
      setConversationTabActivity(
        agentOrchestrationTargetId,
        AgentConversationTabActivity.none,
      );
    } finally {
      isSendingConversationMessage = false;
      agentWorkspaceNotifyStateChanged();
    }
  }

  Future<void> cancelOrchestratedWorkflow() async {
    final workflowId = currentOrchestrationProjection?.workflowId ?? '';
    if (workflowId.isEmpty) return;
    final projection = await orchestratorClient.cancel(
      workflowId: workflowId,
      idempotencyKey: 'workflow-cancel-$workflowId',
    );
    projectOrchestrationWorkflow(projection);
  }

  Future<void> approveOrchestratedWorkflow({
    required String approvalId,
    required bool approved,
  }) async {
    final workflowId = currentOrchestrationProjection?.workflowId ?? '';
    if (workflowId.isEmpty) return;
    final projection = await orchestratorClient.approve(
      workflowId: workflowId,
      approvalId: approvalId,
      decision: approved ? 'approved' : 'rejected',
      idempotencyKey: 'workflow-approval-$workflowId-$approvalId',
    );
    projectOrchestrationWorkflow(projection);
  }
}
