import 'package:path/path.dart' as p;

import 'support/client_controller_scenario_dependencies.dart';
import 'support/client_controller_scenario_environment.dart';
import 'support/fake_agent_service.dart';
import 'support/fake_mobile_relay_service.dart';

void registerClientBootstrapScenarios() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'initializes against portable data without legacy runtime services',
    () async {
      final directory = await Directory.systemTemp.createTemp('lico-licoup-');
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
      addTearDown(controller.dispose);

      await controller.initialize();

      expect(controller.initialized, isTrue);
      expect(controller.portableDataPath, directory.path);
      expect(
        service.scanOneTargetCalls,
        AgentService.packagedScanTargetIds.length,
      );
      expect(controller.scannedTargets, hasLength(1));
      expect(controller.scannedTargets.single.target, 'codex');
      expect(
        controller.selectedConversationAgentId,
        agentOrchestrationTargetId,
      );
      expect(
        await File('${directory.path}/.licoup-workspace.json').exists(),
        isTrue,
      );
    },
  );

  test('desktop initialize surfaces target scan failures', () async {
    final directory = await Directory.systemTemp.createTemp(
      'lico-licoup-scan-failure-',
    );
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });
    final service = FakeAgentService()..throwScanTargets = true;
    final controller = ClientController(
      portableData: PortableDataRoot(dataDirectoryOverride: directory),
      agentService: service,
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    expect(controller.initialized, isTrue);
    expect(
      service.scanOneTargetCalls,
      AgentService.packagedScanTargetIds.length,
    );
    expect(controller.scannedTargets, isEmpty);
    expect(controller.statusCaption, 'Targets');
    expect(controller.statusMessage, '目标适配器扫描失败。');
    expect(controller.lastError, 'target_scan_failed');
  });

  test('persists mobile home pinned order and pinned entries', () async {
    final directory = await Directory.systemTemp.createTemp(
      'lico-mobile-home-layout-',
    );
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });
    final portableData = PortableDataRoot(dataDirectoryOverride: directory);
    final controller = ClientController(
      portableData: portableData,
      agentService: FakeAgentService(),
    );
    addTearDown(controller.dispose);

    await controller.toggleMobileHomeEntryPinned('target:codex');
    await controller.toggleMobileHomeEntryPinned('device:mac');
    await controller.reorderMobileHomePinnedEntries(
      ['target:codex', 'device:mac'],
      1,
      0,
    );

    expect(controller.mobileHomeLayout.order, ['device:mac', 'target:codex']);
    expect(
      controller.mobileHomeLayout.pinnedEntryIds,
      containsAll(['target:codex', 'device:mac']),
    );

    final layoutFile = File(
      '${(await portableData.clientDirectory()).path}/mobile-home-layout.json',
    );
    final raw = await layoutFile.readAsString();
    expect(raw, isNot(contains('"account:')));
    expect(raw, contains('"pinnedEntryIds"'));

    final reloaded = ClientController(
      portableData: portableData,
      agentService: FakeAgentService(),
    );
    addTearDown(reloaded.dispose);

    await reloaded.initialize();

    expect(reloaded.mobileHomeLayout.order.first, 'device:mac');
    expect(
      reloaded.mobileHomeLayout.pinnedEntryIds,
      containsAll(['target:codex', 'device:mac']),
    );
  });

  test('loads and saves local appearance preset preference', () async {
    final directory = await Directory.systemTemp.createTemp(
      'lico-appearance-preference-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final portableData = PortableDataRoot(dataDirectoryOverride: directory);
    final preferencesFile = File(
      '${(await portableData.clientDirectory()).path}/appearance-preferences.json',
    );
    await preferencesFile.writeAsString(
      '{"schemaVersion":1,"appearancePresetId":"sunset-ember"}',
      flush: true,
    );

    final controller = ClientController(
      portableData: portableData,
      agentService: FakeAgentService(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    expect(controller.appearancePresetId, AppearancePresetIds.sunsetEmber);

    await controller.setAppearancePreset(AppearancePresetIds.cappuccinoDark);
    expect(controller.appearancePresetId, AppearancePresetIds.cappuccinoDark);
    expect(
      await preferencesFile.readAsString(),
      contains('"appearancePresetId": "cappuccino-dark"'),
    );
  });

  test('invalid local appearance preset falls back to default-system', () async {
    final directory = await Directory.systemTemp.createTemp(
      'lico-appearance-invalid-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final portableData = PortableDataRoot(dataDirectoryOverride: directory);
    final preferencesFile = File(
      '${(await portableData.clientDirectory()).path}/appearance-preferences.json',
    );
    await preferencesFile.writeAsString(
      '{"schemaVersion":1,"appearancePresetId":"unknown"}',
      flush: true,
    );

    final controller = ClientController(
      portableData: portableData,
      agentService: FakeAgentService(),
    );
    addTearDown(controller.dispose);

    await controller.initialize();
    expect(controller.appearancePresetId, AppearancePresetIds.defaultSystem);
  });

  test('exports client logs from the portable activity file', () async {
    final directory = await Directory.systemTemp.createTemp(
      'licoup-log-export-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final portableData = PortableDataRoot(dataDirectoryOverride: directory);
    final activityLog = await portableData.activityLogFile();
    await activityLog.parent.create(recursive: true);
    await activityLog.writeAsString('{"type":"client.ready"}\n', flush: true);
    final destination = File(p.join(directory.path, 'exported.jsonl'));
    final controller = ClientController(
      portableData: portableData,
      agentService: FakeAgentService(),
    );
    addTearDown(controller.dispose);

    await controller.exportClientLogs(destination.path);

    expect(await destination.readAsString(), '{"type":"client.ready"}\n');
    expect(controller.clientLogExportPath, destination.path);
    expect(controller.isExportingClientLogs, isFalse);
    expect(controller.statusMessage, '客户端日志已导出。');
  });

  test(
    'agent usage background scan updates local tokens without status churn',
    () async {
      final directory = await Directory.systemTemp.createTemp('lico-usage-');
      addTearDown(() => directory.delete(recursive: true));
      final service = FakeAgentService();
      final controller = ClientController(
        portableData: PortableDataRoot(dataDirectoryOverride: directory),
        agentService: service,
      );
      addTearDown(controller.dispose);
      controller
        ..statusMessage = 'steady status'
        ..lastError = 'previous error';

      await controller.scanAgentUsage(forceRefresh: false, showProgress: false);

      expect(service.agentUsageScanCalls, 1);
      expect(controller.agentUsageReport?.totalTokens, 42);
      expect(
        controller.agentUsageReport?.tokenSourceMode,
        'native-metadata-first-incremental',
      );
      expect(controller.statusMessage, 'steady status');
      expect(controller.lastError, 'previous error');
      expect(controller.isScanningAgentUsage, isFalse);
      expect(service.cliCalls.single, isNot(contains('--force-refresh')));
    },
  );

  test('agent usage scan uses one retained native aggregation', () async {
    final service = FakeAgentService();
    final controller = ClientController(agentService: service);
    addTearDown(controller.dispose);

    await controller.scanAgentUsage();

    expect(service.agentUsageScanCalls, 1);
    expect(controller.agentUsageReport?.agent('codex')?.totalTokens, 42);
    expect(controller.agentUsageReport?.totalTokens, 42);
    expect(service.cliCalls.single, contains('--force-refresh'));
    expect(service.cliCalls.single, isNot(contains('--transient')));
    expect(service.cliCalls.single, isNot(contains('--agent')));
  });

  test('agent usage scans share one in-flight refresh', () async {
    final gate = Completer<void>();
    final service = FakeAgentService()..agentUsageScanGate = gate;
    final controller = ClientController(agentService: service);
    addTearDown(controller.dispose);

    final first = controller.scanAgentUsage(showProgress: false);
    await Future<void>.delayed(Duration.zero);
    final second = controller.scanAgentUsage();

    expect(identical(first, second), isTrue);
    expect(service.agentUsageScanCalls, 1);

    gate.complete();
    await Future.wait([first, second]);

    expect(service.agentUsageScanCalls, 1);
  });

  test('agent usage auto refresh is single-flight across re-entry', () async {
    final service = FakeAgentService()
      ..agentUsageReportGate = Completer<void>();
    final controller = ClientController(agentService: service);
    addTearDown(controller.dispose);

    final first = controller.ensureAgentUsageLoadedAndFresh();
    await Future<void>.delayed(Duration.zero);
    final second = controller.ensureAgentUsageLoadedAndFresh();

    expect(identical(first, second), isTrue);
    expect(service.agentUsageReportCalls, 1);
    service.agentUsageReportGate!.complete();
    await Future.wait([first, second]);

    expect(service.agentUsageReportCalls, 1);
    expect(service.agentUsageScanCalls, 1);
  });

  test('empty retained usage result clears the active report', () async {
    final service = FakeAgentService();
    final controller = ClientController(agentService: service);
    addTearDown(controller.dispose);

    await controller.scanAgentUsage();
    expect(controller.agentUsageReport, isNotNull);

    service.agentUsageReportsResult = const [];
    await controller.loadAgentUsageReports();

    expect(controller.agentUsageReports, isEmpty);
    expect(controller.agentUsageReport, isNotNull);
    expect(controller.agentUsageReport?.totalTokens, 42);
  });

  test(
    'malformed retained reports preserve state with a bounded error',
    () async {
      final service = FakeAgentService();
      final controller = ClientController(agentService: service);
      addTearDown(controller.dispose);

      await controller.scanAgentUsage();
      final activeReport = controller.agentUsageReport;
      expect(activeReport, isNotNull);

      service.agentUsageReportsResult = const <String, dynamic>{};
      await controller.loadAgentUsageReports();

      expect(identical(controller.agentUsageReport, activeReport), isTrue);
      expect(controller.agentUsageReports, isNotEmpty);
      expect(controller.lastError, 'agent_usage_reports_failed');
    },
  );

  test('loads external appearance preset configs from portable data', () async {
    final directory = await Directory.systemTemp.createTemp(
      'lico-appearance-external-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final portableData = PortableDataRoot(dataDirectoryOverride: directory);
    final clientDirectory = await portableData.clientDirectory();
    final presetsDirectory = Directory(
      '${clientDirectory.path}/appearance-presets',
    );
    await presetsDirectory.create(recursive: true);
    await File('${presetsDirectory.path}/agent-preview.json').writeAsString('''
{
  "schemaVersion": 1,
  "id": "agent-preview",
  "label": {
    "en": "Agent Preview",
    "zh-CN": "智能体预览"
  },
  "mode": "light",
  "tokens": {
    "bg-base": "#fff7ed",
    "bg-surface": "#ffffff",
    "bg-subtle": "#ffedd5",
    "text-primary": "#1c1917",
    "text-muted": "#78716c",
    "text-on-brand": "#ffffff",
    "brand": "#7c3aed",
    "brand-strong": "#5b21b6",
    "brand-subtle": "#ede9fe",
    "success": "#15803d",
    "warning": "#b45309",
    "danger": "#b91c1c"
  }
}
''', flush: true);
    await File(
      '${clientDirectory.path}/appearance-preferences.json',
    ).writeAsString(
      '{"schemaVersion":1,"appearancePresetId":"agent-preview"}',
      flush: true,
    );

    final controller = ClientController(
      portableData: portableData,
      agentService: FakeAgentService(),
    );
    addTearDown(controller.dispose);

    await controller.initialize();
    expect(controller.appearancePresetId, 'agent-preview');
    expect(controller.appearancePresetLabel, 'Agent Preview');
    expect(
      controller.appearancePresetDirectoryPath,
      p.normalize(presetsDirectory.path),
    );
    expect(
      controller.appearancePresetConfigs.any(
        (config) => config.id == 'agent-preview',
      ),
      isTrue,
    );

    await File(
      '${presetsDirectory.path}/broken.json',
    ).writeAsString('{"schemaVersion": 1, "id": "broken"}', flush: true);
    await controller.reloadAppearancePresets();

    expect(controller.appearancePresetId, 'agent-preview');
    expect(controller.appearancePresetLoadErrors, isNotEmpty);
  });

  test(
    'keeps bounded error state when portable initialization fails',
    () async {
      final controller = ClientController(
        portableData: ThrowingPortableDataRoot(),
        agentService: FakeAgentService(),
      );
      addTearDown(controller.dispose);

      await controller.initialize();

      expect(controller.initialized, isFalse);
      expect(controller.lastError, 'client_initialize_failed');
      expect(controller.statusMessage, '初始化失败。');
      expect(controller.statusCaption, 'Error');
    },
  );

  test(
    'selecting same section keeps state, selecting agents auto scans only once',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lico-section-target-scan-',
      );
      addTearDown(() => deleteTempDirectory(directory));
      final service = FakeAgentService();
      final controller = ClientController(
        portableData: PortableDataRoot(dataDirectoryOverride: directory),
        agentService: service,
      );
      addTearDown(controller.dispose);

      controller.selectSection(ClientSection.settings);
      controller.selectSection(ClientSection.settings);
      expect(controller.currentSection, ClientSection.settings);

      controller.selectSection(ClientSection.agents);
      for (var attempt = 0; attempt < 40; attempt += 1) {
        if (service.scanOneTargetCalls ==
            AgentService.packagedScanTargetIds.length) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      controller.selectSection(ClientSection.agents);
      await Future<void>.delayed(Duration.zero);

      expect(controller.currentSection, ClientSection.agents);
      expect(
        service.scanOneTargetCalls,
        AgentService.packagedScanTargetIds.length,
      );
    },
  );

  test(
    'selecting mobile relay section refreshes public secure mesh status',
    () async {
      final relayService = FakeMobileRelayService();
      final controller = ClientController(
        agentService: FakeAgentService(),
        mobileRelayService: relayService,
      );
      addTearDown(controller.dispose);

      controller.selectSection(ClientSection.mobileRelay);
      await Future<void>.delayed(Duration.zero);

      expect(controller.currentSection, ClientSection.mobileRelay);
      expect(relayService.secureMeshStatusCalls, 1);
      expect(relayService.secureMeshStatusAuthorizeFlags, [false]);
    },
  );
}
