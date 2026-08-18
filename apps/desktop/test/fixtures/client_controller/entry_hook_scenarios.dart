import 'package:licoup/src/application/features/navigation/controller/client_interface_entry_hook_controller.dart';

import 'support/client_controller_scenario_dependencies.dart';
import 'support/fake_agent_service.dart';
import 'support/fake_mobile_relay_service.dart';

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
      final relayService = FakeMobileRelayService();
      final controller = ClientController(
        portableData: PortableDataRoot(dataDirectoryOverride: directory),
        agentService: service,
        mobileRelayService: relayService,
      );
      addTearDown(controller.currentViewTracker.flush);
      addTearDown(controller.dispose);

      await controller.initialize();

      // The restored destination is warm before initialization settles.
      expect(controller.scannedTargets, hasLength(1));
      // Groups outside the restored conversation slice stay deferred until
      // their destination is entered.
      expect(relayService.secureMeshStatusCalls, 0);
      expect(relayService.refreshPairingStatusCalls, 0);
      expect(controller.skillHubSkills, isEmpty);
      expect(controller.statusMessage, isNot(contains('Secure Mesh')));
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
      final relayService = FakeMobileRelayService()
        ..config = MobileRelayConfig.defaults().copyWith(
          stationBaseUrl: 'https://station.example.test',
          pairingId: 'pair-1',
          pcTokenPresent: true,
          paired: true,
        );
      final agentsStarted = Completer<void>();
      final agentsDone = Completer<void>();
      final controller = _EntryHookScenarioClientController(
        portableData: PortableDataRoot(dataDirectoryOverride: directory),
        agentService: FakeAgentService(),
        mobileRelayService: relayService,
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
      expect(relayService.secureMeshStatusCalls, 0);

      controller.selectSection(ClientSection.mobileRelay);
      for (
        var attempt = 0;
        attempt < 200 && relayService.refreshPairingStatusCalls == 0;
        attempt += 1
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }

      expect(controller.mobileRelayCalls, 1);
      expect(relayService.secureMeshStatusCalls, greaterThanOrEqualTo(1));
      expect(
        relayService.secureMeshStatusAuthorizeFlags,
        everyElement(isFalse),
      );
      expect(relayService.refreshPairingStatusCalls, greaterThanOrEqualTo(1));
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
    super.mobileRelayService,
  });

  final Future<void> Function() agentsTask;
  int agentsCalls = 0;
  int mobileRelayCalls = 0;

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
    ClientSection.mobileRelay: ClientInterfaceEntryHookTask(
      section: ClientSection.mobileRelay,
      action: () async {
        mobileRelayCalls += 1;
        await refreshSecureMeshStatus(authorize: false, showProgress: false);
        await refreshMobilePairingStatus();
      },
    ),
  };
}
