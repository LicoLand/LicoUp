import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/application/features/navigation/controller/client_interface_entry_hook_controller.dart';
import 'package:licoup/src/contracts/mobile_relay/mobile_relay_config.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/platform/native_client/native_rpc_priority.dart';
import 'package:licoup/src/platform/storage/portable_data_root.dart';

import 'fixtures/client_controller/support/fake_agent_service.dart';
import 'fixtures/client_controller/support/fake_mobile_relay_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'restored replacement is Hook-free and bootstrap entry starts one cycle',
    () async {
      final context = await _createInstrumentedController();
      final controller = context.controller;

      // Restore is pure state replacement: no entry work at all.
      controller.currentSection = ClientSection.settings;
      await controller.initialize();

      expect(controller.entryEvents, isEmpty);

      controller.selectSection(ClientSection.agents);
      await _until(() => controller.agentsCalls == 1);

      expect(controller.entryEvents, ['agents']);
    },
  );

  test(
    'interactive selection converges on the Facade and routes once',
    () async {
      final context = await _createInstrumentedController();
      final controller = context.controller;

      await controller.initialize();
      expect(controller.entryEvents, ['agents']);

      // Communication slice: models leads at foreground, mobileRelay is a
      // background sibling; both run exactly once per group cycle.
      controller.selectSection(ClientSection.models);
      await _until(
        () => controller.modelsCalls == 1 && controller.mobileRelayCalls == 1,
      );
      expect(controller.modelsBackground, [false]);
      expect(controller.mobileRelayBackground, [true]);
      expect(
        controller.entryEvents.where((event) => event == 'models').length,
        1,
      );
      expect(
        controller.entryEvents.where((event) => event == 'mobileRelay').length,
        1,
      );

      // Movement inside the active communication slice only promotes.
      controller.selectSection(ClientSection.mobileRelay);
      await Future<void>.delayed(Duration.zero);
      expect(controller.mobileRelayCalls, 1);

      // Conversation re-entry starts a fresh conversation cycle.
      controller.selectSection(ClientSection.agents);
      await _until(() => controller.agentsCalls == 2);
      expect(
        controller.entryEvents.where((event) => event == 'agents').length,
        2,
      );
    },
  );

  test(
    'feature slice shares one cycle and re-entry schedules a fresh one',
    () async {
      final context = await _createInstrumentedController();
      final controller = context.controller;
      await controller.initialize();

      controller.selectSection(ClientSection.skillHub);
      await _until(
        () =>
            controller.skillHubCalls == 1 &&
            controller.agentHubCalls == 1 &&
            controller.pluginCalls == 1,
      );
      expect(controller.skillHubBackground, [false]);
      expect(controller.agentHubBackground, [true]);
      expect(controller.pluginBackground, [true]);

      controller.selectSection(ClientSection.agentHub);
      controller.selectSection(ClientSection.pluginManagement);
      await Future<void>.delayed(Duration.zero);
      expect(controller.skillHubCalls, 1);
      expect(controller.agentHubCalls, 1);
      expect(controller.pluginCalls, 1);

      controller.selectSection(ClientSection.settings);
      controller.selectSection(ClientSection.skillHub);
      await _until(
        () =>
            controller.skillHubCalls == 2 &&
            controller.agentHubCalls == 2 &&
            controller.pluginCalls == 2,
      );
    },
  );

  test('mobile interactive entry keeps the deferred target contract', () async {
    final context = await _createInstrumentedController(
      mobileClientRuntimePlatformOverride: true,
    );
    final controller = context.controller;

    controller.selectSection(ClientSection.skillHub);
    await Future<void>.delayed(Duration.zero);
    expect(controller.entryEvents, isEmpty);
  });

  test(
    'communication entry uses only non-authorizing local status APIs',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lico-entry-communication-',
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
      final controller = ClientController(
        portableData: PortableDataRoot(dataDirectoryOverride: directory),
        agentService: FakeAgentService(),
        mobileRelayService: relayService,
      );
      addTearDown(controller.currentViewTracker.flush);
      addTearDown(controller.dispose);

      await controller.initialize();
      controller.selectSection(ClientSection.mobileRelay);
      await _until(() => relayService.refreshPairingStatusCalls >= 1);

      expect(
        relayService.secureMeshStatusAuthorizeFlags,
        everyElement(isFalse),
      );
      expect(relayService.refreshPairingStatusCalls, greaterThanOrEqualTo(1));
    },
  );
}

Future<void> _until(bool Function() condition) async {
  for (var attempt = 0; attempt < 400 && !condition(); attempt += 1) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(condition(), isTrue);
}

Future<_InstrumentedEntryContext> _createInstrumentedController({
  bool mobileClientRuntimePlatformOverride = false,
}) async {
  final directory = await Directory.systemTemp.createTemp('lico-entry-hooks-');
  addTearDown(() async {
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  });
  final controller = _InstrumentedEntryController(
    portableData: PortableDataRoot(dataDirectoryOverride: directory),
    agentService: FakeAgentService(),
    mobileRelayService: FakeMobileRelayService(),
    mobileClientRuntimePlatformOverride: mobileClientRuntimePlatformOverride,
  );
  addTearDown(controller.currentViewTracker.flush);
  addTearDown(controller.dispose);
  return _InstrumentedEntryContext(controller);
}

final class _InstrumentedEntryContext {
  _InstrumentedEntryContext(this.controller);

  final _InstrumentedEntryController controller;
}

/// Instrumented entry lanes that record order, priority, and exact counts
/// through the real Facade and scheduler bindings.
final class _InstrumentedEntryController extends ClientController {
  _InstrumentedEntryController({
    super.portableData,
    super.agentService,
    super.mobileRelayService,
    super.mobileClientRuntimePlatformOverride,
  });

  final List<String> entryEvents = [];
  int agentsCalls = 0;
  int modelsCalls = 0;
  int mobileRelayCalls = 0;
  int agentHubCalls = 0;
  int skillHubCalls = 0;
  int pluginCalls = 0;
  final List<bool> modelsBackground = [];
  final List<bool> mobileRelayBackground = [];
  final List<bool> agentHubBackground = [];
  final List<bool> skillHubBackground = [];
  final List<bool> pluginBackground = [];

  @override
  Map<ClientSection, ClientInterfaceEntryHookTask>
  resolveInterfaceEntryHookTasks() => {
    ClientSection.agents: _lane('agents', () => agentsCalls += 1),
    ClientSection.models: _lane(
      'models',
      () => modelsCalls += 1,
      backgrounds: modelsBackground,
    ),
    ClientSection.mobileRelay: _lane(
      'mobileRelay',
      () => mobileRelayCalls += 1,
      backgrounds: mobileRelayBackground,
    ),
    ClientSection.agentHub: _lane(
      'agentHub',
      () => agentHubCalls += 1,
      backgrounds: agentHubBackground,
    ),
    ClientSection.skillHub: _lane(
      'skillHub',
      () => skillHubCalls += 1,
      backgrounds: skillHubBackground,
    ),
    ClientSection.pluginManagement: _lane(
      'pluginManagement',
      () => pluginCalls += 1,
      backgrounds: pluginBackground,
    ),
  };

  ClientInterfaceEntryHookTask _lane(
    String name,
    void Function() record, {
    List<bool>? backgrounds,
  }) {
    return ClientInterfaceEntryHookTask(
      section: ClientSection.values.byName(name),
      action: () async {
        final token = currentRpcPriorityToken();
        backgrounds?.add(token?.background ?? true);
        entryEvents.add(name);
        record();
      },
    );
  }
}
