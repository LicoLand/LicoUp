import 'package:licoup/src/application/features/agents/workspace/agent_workspace_coordinator.dart';

mixin AgentOrchestrationPresentation on AgentWorkspaceCoordinator {
  String get orchestrationProjectionStatus =>
      orchestrationPolicyDraft.isEmpty ? 'unavailable' : 'ready';
}
