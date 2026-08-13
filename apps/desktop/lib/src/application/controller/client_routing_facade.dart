import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:licoup/src/application/features/agents/workspace/agent_workspace_coordinator.dart';
import 'package:licoup/src/contracts/generated/client_state.g.dart';
import 'package:licoup/src/platform/native_client/agent_service.dart';
import 'package:licoup/src/platform/storage/portable_data_root.dart';

/// Composition-only access to the native client facade.
mixin ClientRoutingFacade on AgentWorkspaceCoordinator {
  AgentService get agentService;

  @override
  Future<void> agentWorkspaceEnsureActivePlanDocument() async {
    try {
      final portable = agentWorkspacePortableData;
      if (portable is! PortableDataRoot) return;
      final clientDir = await portable.clientDirectory();
      final plansDir = Directory(p.join(clientDir.path, 'plans'));
      await plansDir.create(recursive: true);
      final file = File(p.join(plansDir.path, 'active-plan.md'));
      if (!await file.exists()) {
        await file.writeAsString('');
      }
    } on Object {
      // Optional plan file must not block profile selection.
    }
  }

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
}
