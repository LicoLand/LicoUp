import 'package:licoup/src/application/features/agents/workspace/agent_workspace_coordinator.dart';
import 'package:licoup/src/contracts/generated/client_state.g.dart';
import 'package:licoup/src/platform/native_client/agent_service.dart';

/// Composition-only access to the native client facade.
mixin ClientRoutingFacade on AgentWorkspaceCoordinator {
  AgentService get agentService;

  @override
  Future<Map<String, Object?>> agentWorkspaceReadSettingsState() async {
    final result = await agentService.getClientState(
      const ClientStateGetRequest(collection: ClientStateCollection.settings),
    );
    return result.document.content;
  }

  @override
  Future<void> agentWorkspaceWriteSettingsState(
    Map<String, Object?> content,
  ) async {
    await agentService.setClientState(
      ClientStateSetRequest(
        collection: ClientStateCollection.settings,
        document: ClientStateDocument(
          schemaVersion: clientStateSchemaVersion,
          collection: ClientStateCollection.settings,
          content: content,
        ),
      ),
    );
  }

  @override
  Future<Map<String, Object?>> agentWorkspaceReadAdaptiveFlywheelState() async {
    final result = await agentService.getClientState(
      const ClientStateGetRequest(
        collection: ClientStateCollection.adaptiveFlywheel,
      ),
    );
    return result.document.content;
  }

  @override
  Future<void> agentWorkspaceWriteAdaptiveFlywheelState(
    Map<String, Object?> content,
  ) async {
    await agentService.setClientState(
      ClientStateSetRequest(
        collection: ClientStateCollection.adaptiveFlywheel,
        document: ClientStateDocument(
          schemaVersion: clientStateSchemaVersion,
          collection: ClientStateCollection.adaptiveFlywheel,
          content: content,
        ),
      ),
    );
  }
}
