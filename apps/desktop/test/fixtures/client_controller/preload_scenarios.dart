import 'support/client_controller_scenario_dependencies.dart';
import 'support/fake_agent_service.dart';
import 'support/fake_mobile_relay_service.dart';

void registerClientPreloadScenarios() {
  test(
    'initialize preloads remaining sections quietly in the background',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lico-section-preload-',
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

      // The landing section is warm before initialization settles.
      expect(controller.scannedTargets, hasLength(1));

      // Remaining sections finish preloading in the background.
      for (var attempt = 0; attempt < 300; attempt += 1) {
        if (relayService.secureMeshStatusCalls > 0 &&
            controller.skillHubSkills.isNotEmpty) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      expect(relayService.secureMeshStatusCalls, greaterThanOrEqualTo(1));
      expect(
        relayService.secureMeshStatusAuthorizeFlags,
        everyElement(isFalse),
      );
      expect(controller.skillHubSkills, isNotEmpty);
      expect(controller.agentUsageReport, isNotNull);
      // Background preload must not churn the visible status line.
      expect(controller.statusMessage, isNot(contains('Secure Mesh')));
      expect(controller.statusMessage, isNot(contains('技能')));
    },
  );

  test(
    'selecting a section accelerates its pending background preload',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lico-section-preload-boost-',
      );
      addTearDown(() async {
        if (await directory.exists()) {
          await directory.delete(recursive: true);
        }
      });
      final relayService = FakeMobileRelayService();
      final agentsTaskStarted = Completer<void>();
      var agentsTaskDone = false;
      final controller = _PreloadBoostClientController(
        portableData: PortableDataRoot(dataDirectoryOverride: directory),
        agentService: FakeAgentService(),
        mobileRelayService: relayService,
        agentsTask: () async {
          agentsTaskStarted.complete();
          await Future<void>.delayed(const Duration(milliseconds: 600));
          agentsTaskDone = true;
        },
      );
      addTearDown(controller.currentViewTracker.flush);
      addTearDown(controller.dispose);

      final initializing = controller.initialize();
      await agentsTaskStarted.future;

      controller.selectSection(ClientSection.mobileRelay);
      for (
        var attempt = 0;
        attempt < 80 && relayService.secureMeshStatusCalls == 0;
        attempt += 1
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }

      // The boosted task ran immediately instead of waiting for the slow
      // first task and the inter-task idle gap.
      expect(relayService.secureMeshStatusCalls, greaterThanOrEqualTo(1));
      expect(
        relayService.secureMeshStatusAuthorizeFlags,
        everyElement(isFalse),
      );
      expect(agentsTaskDone, isFalse);

      await initializing;
    },
  );
}

/// Keeps the mobile relay preload task pending behind a slow landing-section
/// task so the scenario can boost it through section selection.
final class _PreloadBoostClientController extends ClientController {
  _PreloadBoostClientController({
    required this.agentsTask,
    super.portableData,
    super.agentService,
    super.mobileRelayService,
  });

  final Future<void> Function() agentsTask;

  @override
  Map<ClientSection, Future<void> Function()> resolveSectionPreloadTasks() => {
    ClientSection.agents: agentsTask,
    ClientSection.mobileRelay: () => refreshSecureMeshStatus(authorize: false),
  };
}
