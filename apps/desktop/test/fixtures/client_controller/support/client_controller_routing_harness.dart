import 'package:path/path.dart' as p;

import 'client_controller_scenario_dependencies.dart';
import 'client_controller_scenario_json.dart';
import 'fake_agent_service.dart';

Future<({Directory directory, ClientController controller})>
createRoutingStrategyHarness({
  required String strategy,
  required FakeAgentService service,
}) async {
  final directory = await Directory.systemTemp.createTemp(
    'lico-routing-strategy-',
  );
  final policyFile = File(
    p.join(directory.path, 'lico-client', 'routing', 'routing-policy.json'),
  );
  await policyFile.parent.create(recursive: true);
  await policyFile.writeAsString(
    jsonEncode({
      'schemaVersion': routingPolicySchemaVersion,
      'id': 'strategy-$strategy',
      'label': 'Strategy $strategy',
      'agents': [
        for (final (index, id) in const [
          'codex',
          'claude-code',
          'opencode',
        ].indexed)
          {
            'id': id,
            'modelName': '$id-model',
            'coordinator': index == 0,
            'priority': index + 1,
          },
      ],
      'routing': {'strategy': strategy},
    }),
  );
  service.scanTargetsResult = routingStrategyTargets();
  final controller = ClientController(
    portableData: PortableDataRoot(dataDirectoryOverride: directory),
    agentService: service,
  );
  await controller.initialize();
  expect(
    controller.scannedTargets.map((target) => target.target),
    containsAll(const ['codex', 'claude-code', 'opencode']),
  );
  expect(
    controller
        .routingLifecycleController
        .registration
        ?.activePolicy
        .routing
        .strategy,
    strategy,
  );
  expect(controller.selectedConversationAgentId, agentOrchestrationTargetId);
  return (directory: directory, controller: controller);
}

Future<void> waitForRuntimeMessageCount(
  FakeAgentService service,
  int expected,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (service.runtimeMessageCalls < expected) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('routing strategy dispatch timeout');
    }
    await Future<void>.delayed(Duration.zero);
  }
}
