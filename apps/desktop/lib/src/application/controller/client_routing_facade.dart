import 'package:flutter_client/src/application/features/agents/workspace/agent_workspace_coordinator.dart';
import 'package:flutter_client/src/platform/native_client/agent_service.dart';
import 'package:flutter_client/src/platform/native_client/orchestrator_ipc/client.dart';

/// Composition-only access to the single native orchestration client.
mixin ClientRoutingFacade on AgentWorkspaceCoordinator {
  AgentService get agentService;

  @override
  NativeOrchestratorClient get orchestratorClient =>
      agentService.orchestratorClient;
}
