import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/application/features/agent_hub/agent_hub_catalog_controller.dart';
import 'package:licoup/src/contracts/agent_hub.dart';
import 'package:licoup/src/projections/agent_hub/agent_hub_projection_producer.dart';

void main() {
  test(
    'Agent Hub projection publishes the settled semantic catalog once',
    () async {
      final engine = _FakeAgentHubEngine();
      final owner = AgentHubCatalogController(engine: engine);
      final producer = AgentHubProjectionProducer(owner);
      final updates = <String>[];
      final subscription = producer.changes.listen(
        (update) => updates.add(
          '${update.value.phase.name}:'
          '${update.value.entries.isEmpty ? 'empty' : update.value.entries.single.busy}',
        ),
      );

      await owner.refresh();

      expect(producer.current.entries.single.id, 'synthetic-agent');
      expect(producer.current.entries.single.channels.single.id, 'official');
      expect(producer.current.entries.single.installable, isTrue);
      expect(updates, ['loading:empty', 'loading:true', 'ready:false']);

      await subscription.cancel();
      await producer.dispose();
      owner.dispose();
    },
  );
}

final class _FakeAgentHubEngine implements AgentHubEnginePort {
  static const _recipe = AgentHubRecipe(
    id: 'synthetic-agent',
    displayName: 'Synthetic Agent',
    adaptation: AgentHubAdaptationDepth.deep,
    installable: true,
    summary: 'Synthetic catalog fixture.',
    installChannels: [
      AgentHubInstallChannel(id: 'official', kind: 'official-artifact'),
    ],
  );

  @override
  AgentHubCatalogSnapshot? get cachedCatalog => null;

  @override
  Future<AgentHubCatalogSnapshot> catalog({String recipeId = ''}) async =>
      const AgentHubCatalogSnapshot(recipes: [_recipe]);

  @override
  Future<AgentHubOperationResult> confirm(AgentHubConfirmRequest request) =>
      _result(AgentHubLifecycleAction.confirm, request.recipeId);

  @override
  Future<AgentHubOperationResult> install(AgentHubInstallRequest request) =>
      _result(AgentHubLifecycleAction.install, request.recipeId);

  @override
  Future<AgentHubOperationResult> plan(AgentHubPlanRequest request) =>
      _result(AgentHubLifecycleAction.plan, request.recipeId);

  @override
  Future<AgentHubOperationResult> rescan(AgentHubRescanRequest request) =>
      _result(AgentHubLifecycleAction.rescan, request.recipeId);

  @override
  Future<AgentHubOperationResult> uninstall(AgentHubUninstallRequest request) =>
      _result(AgentHubLifecycleAction.uninstall, request.recipeId);

  @override
  Future<AgentHubOperationResult> update(AgentHubUpdateRequest request) =>
      _result(AgentHubLifecycleAction.update, request.recipeId);

  @override
  Future<AgentHubOperationResult> verify(AgentHubVerifyRequest request) =>
      _result(AgentHubLifecycleAction.verify, request.recipeId);

  Future<AgentHubOperationResult> _result(
    AgentHubLifecycleAction action,
    String recipeId,
  ) async => AgentHubOperationResult(
    status: AgentHubOperationStatus.completed,
    action: action,
    recipeId: recipeId,
  );
}
