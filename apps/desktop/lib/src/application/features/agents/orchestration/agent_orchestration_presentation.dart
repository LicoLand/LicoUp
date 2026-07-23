import 'package:flutter_client/src/application/features/agents/workspace/agent_workspace_coordinator.dart';

mixin AgentOrchestrationPresentation on AgentWorkspaceCoordinator {
  String get orchestrationProjectionStatus =>
      currentOrchestrationProjection?.state ?? 'unavailable';
}
