import 'package:licoup/src/application/features/navigation/controller/client_interface_entry_hook_controller.dart';

import 'support/client_controller_scenario_dependencies.dart';
import 'support/fake_agent_service.dart';

void registerClientEntryHookScenarios() {
  test(
    'initialize warms the restored conversation destination and defers other groups',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lico-entry-hook-',
      );
      addTearDown(() async {
        if (await directory.exists()) {
          await directory.delete(recursive: true);
        }
      });
      final service = FakeAgentService();
      final controller = ClientController(
        portableData: PortableDataRoot(dataDirectoryOverride: directory),
        agentService: service,
      );
      addTearDown(controller.currentViewTracker.flush);
      addTearDown(controller.dispose);

      await controller.initialize();

      // The restored destination is warm before initialization settles.
      expect(controller.scannedTargets, hasLength(1));
      // Groups outside the restored conversation slice stay deferred until
      // their destination is entered.
      expect(
        service.cliCalls.where((call) => call.first == 'devices'),
        isEmpty,
      );
      expect(controller.skillHubSkills, isEmpty);
      expect(controller.statusMessage, isNot(contains('技能')));
    },
  );

  test(
    'bootstrap entry runs one conversation cycle and entry promotes only its group',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lico-entry-hook-cycle-',
      );
      addTearDown(() async {
        if (await directory.exists()) {
          await directory.delete(recursive: true);
        }
      });
      final agentService = FakeAgentService();
      final agentsStarted = Completer<void>();
      final agentsDone = Completer<void>();
      final controller = _EntryHookScenarioClientController(
        portableData: PortableDataRoot(dataDirectoryOverride: directory),
        agentService: agentService,
        agentsTask: () async {
          agentsStarted.complete();
          await agentsDone.future;
        },
      );
      addTearDown(controller.currentViewTracker.flush);
      addTearDown(controller.dispose);

      final initializing = controller.initialize();
      await agentsStarted.future;

      // Conversation re-entry while the bootstrap lane is in flight schedules
      // one newest-trailing cycle instead of a duplicate call.
      controller.selectSection(ClientSection.agents);
      agentsDone.complete();
      await initializing;

      expect(controller.agentsCalls, 2);
      bool devicesStatusRead() => agentService.cliCalls.any(
        (call) =>
            call.length == 2 && call[0] == 'devices' && call[1] == 'status',
      );
      expect(devicesStatusRead(), isFalse);

      controller.selectSection(ClientSection.devices);
      for (
        var attempt = 0;
        attempt < 200 && !devicesStatusRead();
        attempt += 1
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }

      expect(controller.devicesCalls, 1);
      expect(devicesStatusRead(), isTrue);
    },
  );
}

/// Keeps an instrumented conversation lane so the scenario can observe cycle
/// coalescing and verify that entering communication never starts the
/// conversation lane again.
final class _EntryHookScenarioClientController extends ClientController {
  _EntryHookScenarioClientController({
    required this.agentsTask,
    super.portableData,
    super.agentService,
  });

  final Future<void> Function() agentsTask;
  int agentsCalls = 0;
  int devicesCalls = 0;

  @override
  Map<ClientSection, ClientInterfaceEntryHookTask>
  resolveInterfaceEntryHookTasks() => {
    ClientSection.agents: ClientInterfaceEntryHookTask(
      section: ClientSection.agents,
      action: () async {
        agentsCalls += 1;
        await agentsTask();
      },
    ),
    ClientSection.devices: ClientInterfaceEntryHookTask(
      section: ClientSection.devices,
      action: () async {
        devicesCalls += 1;
        await devicesController.refresh();
      },
    ),
  };
}
