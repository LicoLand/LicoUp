import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_client/src/application/controller/future_client_controller.dart';
import 'package:flutter_client/src/application/models/future_client_models.dart';
import 'package:flutter_client/src/contracts/agent_orchestration_policy.dart';
import 'package:flutter_client/src/contracts/agent_usage_models.dart';
import 'package:flutter_client/src/backend/features/agents/services/agent_conversation_service.dart';
import 'package:flutter_client/src/backend/features/mobile_relay/services/mobile_agent_account_service.dart';
import 'package:flutter_client/src/backend/features/mobile_relay/services/mobile_provider_conversation_service.dart';
import 'package:flutter_client/src/platform/native_client/agent_service.dart';
import 'package:flutter_client/src/platform/client_clipboard_service.dart';
import 'package:flutter_client/src/platform/local_runtime/local_runtime_preferences_store.dart';
import 'package:flutter_client/src/contracts/mobile_agent_account.dart';
import 'package:flutter_client/src/contracts/mobile_provider_conversation.dart';
import 'package:flutter_client/src/platform/mobile_relay/mobile_agent_account_store.dart';
import 'package:flutter_client/src/platform/mobile_relay/mobile_provider_conversation_store.dart';
import 'package:flutter_client/src/platform/mobile_relay/mobile_relay_service.dart';
import 'package:flutter_client/src/platform/storage/portable_data_root.dart';
import 'package:flutter_client/src/platform/secure_mesh/secure_mesh_android_bridge.dart';
import 'package:flutter_client/src/platform/secure_mesh/secure_mesh_mobile_bridge.dart';
import 'package:flutter_client/src/contracts/appearance/appearance_preset_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

const Map<String, dynamic> _parityReadyAdapterCapabilities = {
  'conversationDriver': 'implemented',
  'conversationProtocol': 'test-native-protocol',
  'conversationReadiness': 'ready',
};

Future<void> _deleteTempDirectory(Directory directory) async {
  for (var attempt = 0; attempt < 5; attempt += 1) {
    if (!await directory.exists()) {
      return;
    }
    try {
      await directory.delete(recursive: true);
      return;
    } on FileSystemException {
      if (attempt == 4) {
        rethrow;
      }
      await Future<void>.delayed(Duration(milliseconds: 25 * (attempt + 1)));
    }
  }
}

void main() {
  test(
    'initializes against portable data without legacy runtime services',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lico-future-client-',
      );
      addTearDown(() async {
        if (await directory.exists()) {
          await directory.delete(recursive: true);
        }
      });

      final service = _FakeAgentService();
      final controller = FutureClientController(
        portableData: PortableDataRoot(dataDirectoryOverride: directory),
        agentService: service,
      );
      addTearDown(controller.dispose);

      await controller.initialize();

      expect(controller.initialized, isTrue);
      expect(controller.portableDataPath, directory.path);
      expect(service.scanTargetsCalls, 1);
      expect(controller.scannedTargets, hasLength(1));
      expect(controller.scannedTargets.single.target, 'codex');
      expect(
        controller.selectedConversationAgentId,
        agentOrchestrationTargetId,
      );
      expect(
        await File('${directory.path}/.lico-workspace.json').exists(),
        isTrue,
      );
    },
  );

  test('desktop initialize surfaces target scan failures', () async {
    final directory = await Directory.systemTemp.createTemp(
      'lico-future-client-scan-failure-',
    );
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });
    final service = _FakeAgentService()..throwScanTargets = true;
    final controller = FutureClientController(
      portableData: PortableDataRoot(dataDirectoryOverride: directory),
      agentService: service,
    );
    addTearDown(controller.dispose);

    await controller.initialize();

    expect(controller.initialized, isTrue);
    expect(service.scanTargetsCalls, 1);
    expect(controller.scannedTargets, isEmpty);
    expect(controller.statusCaption, 'Targets');
    expect(controller.statusMessage, '目标适配器扫描失败。');
    expect(controller.lastError, contains('scan failed'));
  });

  test('adds mobile agent provider accounts without persisted secrets', () async {
    final directory = await Directory.systemTemp.createTemp(
      'lico-mobile-agent-accounts-',
    );
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });
    final portableData = PortableDataRoot(dataDirectoryOverride: directory);
    final controller = FutureClientController(
      portableData: portableData,
      agentService: _FakeAgentService(),
    );
    addTearDown(controller.dispose);

    await controller.addMobileAgentProvider('gemini');

    expect(controller.mobileAgentAccounts, hasLength(1));
    expect(controller.mobileAgentAccounts.single.providerId, 'gemini');
    expect(controller.mobileAgentAccounts.single.credentialPresent, isFalse);

    await controller.configureMobileAgentApiKey(
      providerId: 'gemini',
      apiKey: ['dummy-gemini', '-api-key-1234'].join(),
    );

    expect(controller.mobileAgentAccounts.single.credentialPresent, isTrue);
    expect(controller.mobileAgentAccounts.single.credentialHint, '**** 1234');

    final accountsFile = File(
      '${(await portableData.futureClientDirectory()).path}/mobile-agent-accounts.json',
    );
    final raw = await accountsFile.readAsString();
    expect(raw, contains('"providerId": "gemini"'));
    expect(raw, contains('"credentialPresent": true'));
    expect(raw, contains('"credentialHint": "**** 1234"'));
    expect(raw, isNot(contains('dummy-gemini-api-key-1234')));
    expect(raw, isNot(contains('token')));
    expect(raw, isNot(contains('apiKey')));

    final reloaded = FutureClientController(
      portableData: portableData,
      agentService: _FakeAgentService(),
    );
    addTearDown(reloaded.dispose);

    await reloaded.initialize();

    expect(reloaded.mobileAgentAccounts, hasLength(1));
    expect(reloaded.mobileAgentAccounts.single.providerId, 'gemini');
    expect(reloaded.mobileAgentAccounts.single.credentialPresent, isTrue);
    expect(reloaded.mobileAgentAccounts.single.credentialHint, '**** 1234');
  });

  test(
    'deletes mobile provider accounts and clears home layout entries',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lico-mobile-agent-delete-',
      );
      addTearDown(() async {
        if (await directory.exists()) {
          await directory.delete(recursive: true);
        }
      });
      final portableData = PortableDataRoot(dataDirectoryOverride: directory);
      final controller = FutureClientController(
        portableData: portableData,
        agentService: _FakeAgentService(),
      );
      addTearDown(controller.dispose);

      await controller.addMobileAgentProvider('gemini');
      await controller.addMobileAgentProvider('deepseek');
      await controller.toggleMobileHomeEntryPinned('account:gemini');
      await controller.reorderMobileHomePinnedEntries(['account:gemini'], 0, 0);

      expect(controller.mobileAgentAccounts.map((account) => account.id), [
        'gemini',
        'deepseek',
      ]);
      expect(
        controller.mobileHomeLayout.pinnedEntryIds,
        contains('account:gemini'),
      );

      await controller.deleteMobileAgentAccounts(['gemini']);

      expect(controller.mobileAgentAccounts.map((account) => account.id), [
        'deepseek',
      ]);
      expect(
        controller.mobileHomeLayout.pinnedEntryIds,
        isNot(contains('account:gemini')),
      );
      expect(
        controller.mobileHomeLayout.order,
        isNot(contains('account:gemini')),
      );

      final reloaded = FutureClientController(
        portableData: portableData,
        agentService: _FakeAgentService(),
      );
      addTearDown(reloaded.dispose);
      await reloaded.initialize();

      expect(reloaded.mobileAgentAccounts.map((account) => account.id), [
        'deepseek',
      ]);
    },
  );

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
    final controller = FutureClientController(
      portableData: portableData,
      agentService: _FakeAgentService(),
    );
    addTearDown(controller.dispose);

    await controller.toggleMobileHomeEntryPinned('target:codex');
    await controller.toggleMobileHomeEntryPinned('device:mac');
    await controller.toggleMobileHomeEntryPinned('account:chatgpt');
    await controller.reorderMobileHomePinnedEntries(
      ['target:codex', 'device:mac', 'account:chatgpt'],
      2,
      0,
    );

    expect(controller.mobileHomeLayout.order, [
      'account:chatgpt',
      'target:codex',
      'device:mac',
    ]);
    expect(
      controller.mobileHomeLayout.pinnedEntryIds,
      containsAll(['account:chatgpt', 'target:codex', 'device:mac']),
    );

    final layoutFile = File(
      '${(await portableData.futureClientDirectory()).path}/mobile-home-layout.json',
    );
    final raw = await layoutFile.readAsString();
    expect(raw, contains('"account:chatgpt"'));
    expect(raw, contains('"pinnedEntryIds"'));

    final reloaded = FutureClientController(
      portableData: portableData,
      agentService: _FakeAgentService(),
    );
    addTearDown(reloaded.dispose);

    await reloaded.initialize();

    expect(reloaded.mobileHomeLayout.order.first, 'account:chatgpt');
    expect(
      reloaded.mobileHomeLayout.pinnedEntryIds,
      containsAll(['account:chatgpt', 'target:codex', 'device:mac']),
    );
  });

  test('loads and saves local appearance preset preference', () async {
    final directory = await Directory.systemTemp.createTemp(
      'lico-appearance-preference-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final portableData = PortableDataRoot(dataDirectoryOverride: directory);
    final preferencesFile = File(
      '${(await portableData.futureClientDirectory()).path}/appearance-preferences.json',
    );
    await preferencesFile.writeAsString(
      '{"schemaVersion":1,"appearancePresetId":"sunset-ember"}',
      flush: true,
    );

    final controller = FutureClientController(
      portableData: portableData,
      agentService: _FakeAgentService(),
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
      '${(await portableData.futureClientDirectory()).path}/appearance-preferences.json',
    );
    await preferencesFile.writeAsString(
      '{"schemaVersion":1,"appearancePresetId":"unknown"}',
      flush: true,
    );

    final controller = FutureClientController(
      portableData: portableData,
      agentService: _FakeAgentService(),
    );
    addTearDown(controller.dispose);

    await controller.initialize();
    expect(controller.appearancePresetId, AppearancePresetIds.defaultSystem);
  });

  test('local runtime preferences drive ensure flow', () async {
    final directory = await Directory.systemTemp.createTemp(
      'lico-local-runtime-controller-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final portableData = PortableDataRoot(dataDirectoryOverride: directory);
    final service = _FakeAgentService();
    final controller = FutureClientController(
      portableData: portableData,
      agentService: service,
      localRuntimePreferencesStore:
          const PlatformLocalRuntimePreferencesStore(),
    );
    addTearDown(controller.dispose);

    await controller.initialize();
    await controller.ensureLocalRuntime(
      sourceRoot: '/repo',
      presetConfig: '/repo/preset.json',
      port: 17329,
    );

    expect(service.ensureLocalRuntimeCalls, 1);
    expect(service.localRuntimeSourceRoot, '/repo');
    expect(service.localRuntimePresetConfig, '/repo/preset.json');
    expect(service.localRuntimePort, 17329);
    expect(controller.localRuntimePreferences.sourceRoot, '/repo');
    expect(
      controller.localRuntimePreferences.presetConfig,
      '/repo/preset.json',
    );
    expect(controller.localRuntimePreferences.port, 17329);
    expect(controller.localRuntimeState?['running'], isTrue);
    expect(controller.statusMessage, '本地服务端已就绪。');
  });

  test('local runtime logs are loaded into controller state', () async {
    final directory = await Directory.systemTemp.createTemp(
      'lico-local-runtime-logs-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final service = _FakeAgentService();
    final controller = FutureClientController(
      portableData: PortableDataRoot(dataDirectoryOverride: directory),
      agentService: service,
    );
    addTearDown(controller.dispose);

    await controller.loadLocalRuntimeLogs(tail: 2);

    expect(service.localRuntimeLogsCalls, 1);
    expect(service.localRuntimeLogsTail, 2);
    expect(controller.localRuntimeLogLines, ['line-a', 'line-b']);
  });

  test('exports client logs from the portable activity file', () async {
    final directory = await Directory.systemTemp.createTemp(
      'lico-client-log-export-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final portableData = PortableDataRoot(dataDirectoryOverride: directory);
    final activityLog = await portableData.activityLogFile();
    await activityLog.parent.create(recursive: true);
    await activityLog.writeAsString('{"type":"client.ready"}\n', flush: true);
    final destination = File(p.join(directory.path, 'exported.jsonl'));
    final controller = FutureClientController(
      portableData: portableData,
      agentService: _FakeAgentService(),
    );
    addTearDown(controller.dispose);

    await controller.exportClientLogs(destination.path);

    expect(await destination.readAsString(), '{"type":"client.ready"}\n');
    expect(controller.clientLogExportPath, destination.path);
    expect(controller.isExportingClientLogs, isFalse);
    expect(controller.statusMessage, '客户端日志已导出。');
  });

  test(
    'agent usage background scan updates token and traffic without status churn',
    () async {
      final directory = await Directory.systemTemp.createTemp('lico-usage-');
      addTearDown(() => directory.delete(recursive: true));
      final service = _FakeAgentService();
      final controller = FutureClientController(
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
      expect(controller.agentUsageReport?.agent('codex')?.attribution, 'mixed');
      expect(controller.statusMessage, 'steady status');
      expect(controller.lastError, 'previous error');
      expect(controller.isScanningAgentUsage, isFalse);
      expect(service.cliCalls.single, isNot(contains('--force-refresh')));
    },
  );

  test('agent usage scan uses one retained native aggregation', () async {
    final service = _FakeAgentService();
    final controller = FutureClientController(agentService: service);
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
    final service = _FakeAgentService()..agentUsageScanGate = gate;
    final controller = FutureClientController(agentService: service);
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

  test(
    'refreshAgentAllowances caches scoped quota without replacing report',
    () async {
      final service = _FakeAgentService()
        ..agentUsageScanResult = {
          'ok': true,
          'schemaVersion': 2,
          'generatedAt': '2026-07-01T00:00:00Z',
          'summary': {'agentCount': 1, 'totalTokens': 0},
          'agents': [
            {
              'agentId': 'codex',
              'label': 'Codex',
              'allowances': [
                {
                  'kind': 'chatgpt-weekly-limit',
                  'label': 'ChatGPT weekly limit',
                  'provider': 'ChatGPT',
                  'period': 'week',
                  'status': 'available',
                  'value': '73%',
                  'unit': '',
                  'source': 'codex-oauth:system',
                  'message': 'ChatGPT quota window.',
                },
              ],
            },
          ],
        };
      final controller = FutureClientController(agentService: service);
      addTearDown(controller.dispose);

      await controller.refreshAgentAllowances('codex');

      expect(service.agentUsageScanCalls, 1);
      expect(service.agentUsageAgent, 'codex');
      expect(service.cliCalls.single, [
        'agent-usage',
        'scan',
        '--agent',
        'codex',
        '--allowances-only',
      ]);
      expect(controller.agentUsageReport, isNull);
      expect(controller.allowancesForAgent('codex').single.value, '73%');
    },
  );

  test(
    'empty scoped allowance result authoritatively hides stale allowances',
    () async {
      final service = _FakeAgentService()
        ..agentUsageScanResult = {
          'ok': true,
          'schemaVersion': 2,
          'generatedAt': '2026-07-01T00:00:00Z',
          'summary': {'agentCount': 0, 'totalTokens': 0},
          'agents': const [],
        };
      const staleCodexAllowance = AgentUsageAllowance(
        kind: 'chatgpt-weekly-limit',
        label: 'ChatGPT weekly limit',
        provider: 'ChatGPT',
        period: 'week',
        status: 'available',
        value: '73%',
        unit: '',
        source: 'test',
        message: 'Cached quota.',
      );
      final controller = FutureClientController(agentService: service)
        ..agentUsageReport = AgentUsageReport(
          schemaVersion: AgentUsageReport.currentSchemaVersion,
          generatedAt: '2026-06-30T00:00:00Z',
          summary: const {},
          agents: const [
            AgentUsageAgentSummary(
              agentId: 'codex',
              label: 'Codex',
              status: 'detected',
              history: {},
              traffic: {},
              allowances: [staleCodexAllowance],
              confidence: 'medium',
            ),
          ],
          warnings: const [],
        )
        ..agentAllowanceOverrides = const {
          'codex': [staleCodexAllowance],
          'opencode': [
            AgentUsageAllowance(
              kind: 'credits',
              label: 'OpenCode credits',
              provider: 'OpenCode',
              period: 'balance',
              status: 'available',
              value: '5',
              unit: 'credits',
              source: 'test',
              message: 'Cached credits.',
            ),
          ],
        };
      addTearDown(controller.dispose);

      await controller.refreshAgentAllowances('codex');

      expect(controller.allowancesForAgent('codex'), isEmpty);
      expect(controller.agentAllowanceOverrides, contains('codex'));
      expect(controller.agentAllowanceOverrides['codex'], isEmpty);
      expect(controller.allowancesForAgent('opencode').single.value, '5');
    },
  );

  test('agent usage auto refresh is single-flight across re-entry', () async {
    final service = _FakeAgentService()
      ..agentUsageReportGate = Completer<void>();
    final controller = FutureClientController(agentService: service);
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
    final service = _FakeAgentService();
    final controller = FutureClientController(agentService: service);
    addTearDown(controller.dispose);

    await controller.scanAgentUsage();
    expect(controller.agentUsageReport, isNotNull);

    service.agentUsageReportsResult = const [];
    await controller.loadAgentUsageReports();

    expect(controller.agentUsageReports, isEmpty);
    expect(controller.agentUsageReport, isNull);
  });

  test('malformed retained reports preserve the active report', () async {
    final service = _FakeAgentService();
    final controller = FutureClientController(agentService: service);
    addTearDown(controller.dispose);

    await controller.scanAgentUsage();
    final activeReport = controller.agentUsageReport;
    expect(activeReport, isNotNull);

    service.agentUsageReportsResult = const <String, dynamic>{};
    await controller.loadAgentUsageReports();

    expect(identical(controller.agentUsageReport, activeReport), isTrue);
    expect(controller.agentUsageReports, isNotEmpty);
    expect(controller.lastError, contains('FormatException'));
  });

  test('loads external appearance preset configs from portable data', () async {
    final directory = await Directory.systemTemp.createTemp(
      'lico-appearance-external-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final portableData = PortableDataRoot(dataDirectoryOverride: directory);
    final futureClientDirectory = await portableData.futureClientDirectory();
    final presetsDirectory = Directory(
      '${futureClientDirectory.path}/appearance-presets',
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
      '${futureClientDirectory.path}/appearance-preferences.json',
    ).writeAsString(
      '{"schemaVersion":1,"appearancePresetId":"agent-preview"}',
      flush: true,
    );

    final controller = FutureClientController(
      portableData: portableData,
      agentService: _FakeAgentService(),
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

  test('keeps error state when portable data initialization fails', () async {
    final controller = FutureClientController(
      portableData: _ThrowingPortableDataRoot(),
      agentService: _FakeAgentService(),
    );
    addTearDown(controller.dispose);

    await controller.initialize();

    expect(controller.initialized, isFalse);
    expect(controller.lastError, contains('boot error'));
    expect(controller.statusMessage, '初始化失败。');
    expect(controller.statusCaption, 'Error');
  });

  test(
    'selecting same section keeps state, selecting agents auto scans only once',
    () async {
      final service = _FakeAgentService();
      final controller = FutureClientController(agentService: service);
      addTearDown(controller.dispose);

      controller.selectSection(FutureClientSection.settings);
      controller.selectSection(FutureClientSection.settings);
      expect(controller.currentSection, FutureClientSection.settings);

      controller.selectSection(FutureClientSection.agents);
      await Future<void>.delayed(Duration.zero);

      controller.selectSection(FutureClientSection.agents);
      await Future<void>.delayed(Duration.zero);

      expect(controller.currentSection, FutureClientSection.agents);
      expect(service.scanTargetsCalls, 1);
    },
  );

  test(
    'selecting mobile relay section refreshes public secure mesh status',
    () async {
      final relayService = _FakeMobileRelayService();
      final controller = FutureClientController(
        agentService: _FakeAgentService(),
        mobileRelayService: relayService,
      );
      addTearDown(controller.dispose);

      controller.selectSection(FutureClientSection.mobileRelay);
      await Future<void>.delayed(Duration.zero);

      expect(controller.currentSection, FutureClientSection.mobileRelay);
      expect(relayService.secureMeshStatusCalls, 1);
      expect(relayService.secureMeshStatusAuthorizeFlags, [false]);
    },
  );

  test('scanTargets captures failed scans and clears busy flag', () async {
    final service = _FakeAgentService()..throwScanTargets = true;
    final controller = FutureClientController(agentService: service);
    addTearDown(controller.dispose);

    await controller.scanTargets();

    expect(controller.isScanningTargets, isFalse);
    expect(controller.scannedTargets, isEmpty);
    expect(controller.lastError, contains('scan failed'));
    expect(controller.statusMessage, '目标适配器扫描失败。');
    expect(controller.statusCaption, 'Targets');
  });

  test(
    'reorders conversation agent tabs without treating VS Code as an agent',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lico-agent-tab-order-',
      );
      addTearDown(() async {
        if (await directory.exists()) {
          await directory.delete(recursive: true);
        }
      });
      final controller = FutureClientController(
        portableData: PortableDataRoot(dataDirectoryOverride: directory),
        agentService: _FakeAgentService(),
      );
      addTearDown(controller.dispose);
      final targets = [
        TargetCandidate(
          target: 'claude-code',
          label: 'Claude Code',
          kind: 'cli',
          status: 'detected',
          configured: false,
          confidence: 0.9,
          adapterStatus: 'implemented',
        ),
        TargetCandidate(
          target: 'code',
          label: 'VS Code',
          kind: 'desktop-agent',
          status: 'detected',
          configured: false,
          confidence: 0.8,
          adapterStatus: 'unsupported',
        ),
        TargetCandidate(
          target: 'codex',
          label: 'Codex',
          kind: 'cli',
          status: 'detected',
          configured: false,
          confidence: 0.82,
          adapterStatus: 'implemented',
        ),
        TargetCandidate(
          target: 'opencode',
          label: 'OpenCode',
          kind: 'cli',
          status: 'detected',
          configured: false,
          confidence: 0.72,
          adapterStatus: 'implemented',
        ),
      ];

      final visibleTabs = controller.orderedConversationTargets(targets);
      expect(visibleTabs.map((target) => target.target), [
        agentOrchestrationTargetId,
        'claude-code',
        'codex',
        'opencode',
      ]);

      await controller.reorderConversationAgentTabs(visibleTabs, 3, 1);

      expect(controller.agentTabOrder, ['opencode', 'claude-code', 'codex']);
      expect(
        await File(
          p.join(directory.path, 'future-client', 'agent-tab-order.json'),
        ).exists(),
        isTrue,
      );
      expect(
        controller
            .orderedConversationTargets(targets)
            .map((target) => target.target),
        [agentOrchestrationTargetId, 'opencode', 'claude-code', 'codex'],
      );

      await controller.reorderConversationAgentTabs(
        controller.orderedConversationTargets(targets),
        1,
        3,
      );

      expect(controller.agentTabOrder, ['claude-code', 'codex', 'opencode']);

      final reloaded = FutureClientController(
        portableData: PortableDataRoot(dataDirectoryOverride: directory),
        agentService: _FakeAgentService()..scanTargetsResult = targets,
      );
      addTearDown(reloaded.dispose);

      await reloaded.initialize();

      expect(reloaded.agentTabOrder, ['claude-code', 'codex', 'opencode']);
      expect(
        reloaded
            .orderedConversationTargets(targets)
            .map((target) => target.target),
        [agentOrchestrationTargetId, 'claude-code', 'codex', 'opencode'],
      );
    },
  );

  test('scanTargets selects an agent and loads native agent history', () async {
    final directory = await Directory.systemTemp.createTemp('lico-agent-chat-');
    addTearDown(() => directory.delete(recursive: true));
    final service = _FakeAgentService()
      ..scanTargetsResult = [
        TargetCandidate(
          target: 'code',
          label: 'VS Code',
          kind: 'desktop-agent',
          status: 'detected',
          configured: false,
          confidence: 0.9,
          adapterStatus: 'unsupported',
        ),
        TargetCandidate(
          target: 'codex',
          label: 'Codex',
          kind: 'cli',
          status: 'detected',
          configured: false,
          confidence: 0.82,
          detail: 'cli',
          manual: false,
          configPath: '/tmp/codex.toml',
          adapterStatus: 'implemented',
          adapterCapabilities: _parityReadyAdapterCapabilities,
          supportedActions: [
            'mcp.plugin.status',
            'mcp.plugin.update',
            'mcp.plugin.rollback',
            'runtime.message.send',
          ],
        ),
      ]
      ..conversationSessions['codex'] = [
        _conversationSessionJson(
          id: 'native-codex-1',
          agentId: 'codex',
          text: 'Hello from native Codex history',
        ),
      ];
    final controller = FutureClientController(
      portableData: PortableDataRoot(dataDirectoryOverride: directory),
      agentService: service,
    );
    addTearDown(controller.dispose);

    await controller.scanTargets();
    expect(controller.selectedConversationAgentId, agentOrchestrationTargetId);
    expect(controller.selectedConversationSessions, hasLength(1));
    expect(
      controller.selectedConversationSession?.agentId,
      agentOrchestrationTargetId,
    );

    await controller.selectConversationAgent('codex');

    expect(controller.selectedConversationAgentId, 'codex');
    expect(controller.selectedConversationSessions, hasLength(1));
    expect(controller.selectedConversationSession?.messages, hasLength(2));
    expect(
      controller.selectedConversationSession?.messages.first.text,
      'Hello from native Codex history',
    );
    expect(controller.statusMessage, contains('已读取 1 条 codex 原生历史'));
    controller.localePreference = 'en';
    expect(controller.displayStatusMessage, 'Read 1 native codex session.');
  });

  test(
    'mobile agent selection loads native sessions and resumes the exact id',
    () async {
      final agentService = _FakeAgentService();
      final relayService = _FakeMobileRelayService()
        ..secureAgentSessions['codex'] = [
          _conversationSessionJson(
            id: 'codex-projection-new',
            nativeSessionId: 'codex-native-new',
            agentId: 'codex',
            text: 'New native conversation',
            updatedAt: '2026-07-10T00:00:02Z',
          ),
          _conversationSessionJson(
            id: 'codex-projection-exact',
            nativeSessionId: 'codex-native-exact',
            agentId: 'codex',
            text: 'Exact native conversation',
            updatedAt: '2026-07-10T00:00:01Z',
          ),
        ];
      final controller = FutureClientController(
        agentService: agentService,
        mobileRelayService: relayService,
        mobileClientRuntimePlatformOverride: true,
      );
      addTearDown(controller.dispose);
      controller.scannedTargets = [
        TargetCandidate(
          target: 'codex',
          label: 'Codex',
          kind: 'cli',
          status: 'detected',
          configured: true,
          confidence: 0.9,
          adapterStatus: 'implemented',
          adapterCapabilities: _parityReadyAdapterCapabilities,
          supportedActions: const ['runtime.message.send'],
        ),
      ];

      await controller.selectConversationAgent('codex');

      expect(relayService.secureAgentSessionListCalls, 1);
      expect(relayService.lastSecureAgentSessionListAgentId, 'codex');
      expect(relayService.lastSecureAgentSessionListLimit, 20);
      expect(agentService.conversationStreamCalls, 0);
      expect(agentService.conversationListCalls, 0);
      expect(controller.selectedConversationSessions, hasLength(2));
      expect(
        controller.selectedConversationSessions.last.nativeSessionId,
        'codex-native-exact',
      );

      controller.selectConversationSession('codex-projection-exact');
      await controller.sendConversationMessage('Continue this exact thread');

      expect(relayService.secureAgentMessageCalls, 1);
      expect(relayService.lastAgentSessionId, 'codex-native-exact');
      expect(controller.selectedConversationSessions, hasLength(2));
      expect(
        controller.selectedConversationSession?.id,
        'codex-projection-exact',
      );
      expect(
        controller.selectedConversationSession?.nativeSessionId,
        'codex-native-exact',
      );
      expect(agentService.conversationAppendCalls, 0);
    },
  );

  test(
    'mobile native session load fails closed without latest fallback',
    () async {
      final relayService = _FakeMobileRelayService()
        ..secureAgentSessionListResult = const {
          'ok': false,
          'errorCode': 'secure_agent_sessions_denied',
          'error': 'private-native-history-canary',
        };
      final controller = FutureClientController(
        agentService: _FakeAgentService(),
        mobileRelayService: relayService,
        mobileClientRuntimePlatformOverride: true,
      );
      addTearDown(controller.dispose);
      controller.scannedTargets = [
        TargetCandidate(
          target: 'codex',
          label: 'Codex',
          kind: 'cli',
          status: 'detected',
          configured: true,
          confidence: 0.9,
          adapterStatus: 'implemented',
          adapterCapabilities: _parityReadyAdapterCapabilities,
          supportedActions: const ['runtime.message.send'],
        ),
      ];
      controller.selectedConversationAgentId = 'codex';
      controller.selectedConversationSessionId = 'stale-projection';
      controller.conversationSessionsByAgent = {
        'codex': [
          AgentConversationSession.fromJson(
            _conversationSessionJson(
              id: 'stale-projection',
              nativeSessionId: 'stale-native-session',
              agentId: 'codex',
              text: 'Stale native history',
            ),
          ),
        ],
      };

      await controller.loadConversationSessions('codex');

      expect(relayService.secureAgentSessionListCalls, 1);
      expect(controller.selectedConversationSessions, isEmpty);
      expect(controller.selectedConversationSession, isNull);
      expect(controller.selectedConversationSessionId, 'stale-projection');
      expect(controller.lastError, 'secure_agent_sessions_denied');
      expect(controller.lastError, isNot(contains('private-native-history')));
      expect(controller.statusMessage, contains('未选择其他会话'));

      await controller.sendConversationMessage('must not create a new thread');

      expect(relayService.secureAgentMessageCalls, 0);
      expect(controller.lastError, 'native_session_unresolved');
    },
  );

  test(
    'loadConversationSessions streams and keeps latest history first',
    () async {
      final service = _FakeAgentService()
        ..conversationSessions['codex'] = [
          _conversationSessionJson(
            id: 'native-codex-old',
            agentId: 'codex',
            text: 'Older native Codex history',
            updatedAt: '2026-06-12T00:00:01Z',
          ),
          _conversationSessionJson(
            id: 'native-codex-new',
            agentId: 'codex',
            text: 'Newer native Codex history',
            updatedAt: '2026-06-13T00:00:01Z',
          ),
        ];
      final controller = FutureClientController(agentService: service);
      addTearDown(controller.dispose);

      controller.selectedConversationAgentId = 'codex';
      await controller.loadConversationSessions('codex');

      expect(service.conversationStreamCalls, 1);
      expect(service.conversationListCalls, 0);
      expect(
        controller.selectedConversationSessions.map((session) => session.id),
        ['native-codex-new', 'native-codex-old'],
      );
      expect(controller.selectedConversationSession?.id, 'native-codex-new');
    },
  );

  test(
    'loadConversationSessions reveals native history in pages of fifty',
    () async {
      final pagedSessions = List.generate(120, (index) {
        final updatedAt = DateTime.utc(
          2026,
          6,
          12,
        ).add(Duration(minutes: 120 - index)).toIso8601String();
        return _conversationSessionJson(
          id: 'native-codex-${index.toString().padLeft(3, '0')}',
          agentId: 'codex',
          text: 'Paged native Codex history $index',
          updatedAt: updatedAt,
        );
      });
      final service = _FakeAgentService()
        ..conversationSessions['codex'] = pagedSessions;
      final controller = FutureClientController(agentService: service);
      addTearDown(controller.dispose);

      controller.selectedConversationAgentId = 'codex';
      await controller.loadConversationSessions('codex');

      expect(service.conversationStreamCalls, 1);
      expect(service.cliCalls.last, [
        'conversations',
        'stream',
        '--agent',
        'codex',
        '--limit',
        '51',
      ]);
      expect(controller.selectedConversationSessions, hasLength(50));
      expect(
        controller.selectedConversationSessions.first.id,
        'native-codex-000',
      );
      expect(
        controller.selectedConversationSessions.last.id,
        'native-codex-049',
      );
      expect(controller.selectedConversationSessionsHasMore, isTrue);

      await controller.loadMoreConversationSessions('codex');

      expect(service.conversationStreamCalls, 2);
      expect(service.cliCalls.last, [
        'conversations',
        'stream',
        '--agent',
        'codex',
        '--limit',
        '51',
        '--offset',
        '50',
      ]);
      expect(controller.selectedConversationSessions, hasLength(100));
      expect(
        controller.selectedConversationSessions.last.id,
        'native-codex-099',
      );
      expect(controller.selectedConversationSessionsHasMore, isTrue);

      await controller.loadMoreConversationSessions('codex');

      expect(service.conversationStreamCalls, 3);
      expect(service.cliCalls.last, [
        'conversations',
        'stream',
        '--agent',
        'codex',
        '--limit',
        '51',
        '--offset',
        '100',
      ]);
      expect(controller.selectedConversationSessions, hasLength(120));
      expect(
        controller.selectedConversationSessions.last.id,
        'native-codex-119',
      );
      expect(controller.selectedConversationSessionsHasMore, isFalse);
    },
  );

  test(
    'refreshConversationSessions silently inserts newer history first',
    () async {
      final service = _FakeAgentService()
        ..conversationSessions['codex'] = [
          _conversationSessionJson(
            id: 'native-codex-old',
            agentId: 'codex',
            text: 'Older native Codex history',
            updatedAt: '2026-06-12T00:00:01Z',
          ),
        ];
      final controller = FutureClientController(agentService: service);
      addTearDown(controller.dispose);

      controller.selectedConversationAgentId = 'codex';
      await controller.loadConversationSessions('codex');

      expect(controller.isLoadingConversations, isFalse);
      expect(service.conversationStreamCalls, 1);
      expect(
        controller.selectedConversationSessions.map((session) => session.id),
        ['native-codex-old'],
      );

      service.conversationSessions['codex'] = [
        _conversationSessionJson(
          id: 'native-codex-new',
          agentId: 'codex',
          text: 'Newer native Codex history',
          updatedAt: '2026-06-14T00:00:01Z',
        ),
        _conversationSessionJson(
          id: 'native-codex-old',
          agentId: 'codex',
          text: 'Older native Codex history',
          updatedAt: '2026-06-12T00:00:01Z',
        ),
      ];

      await controller.refreshConversationSessions('codex');

      expect(controller.isLoadingConversations, isFalse);
      expect(service.conversationStreamCalls, 2);
      expect(
        controller.selectedConversationSessions.map((session) => session.id),
        ['native-codex-new', 'native-codex-old'],
      );
      expect(controller.selectedConversationSession?.id, 'native-codex-new');
    },
  );

  test(
    'new conversation stays unselected across refresh and sends without session id',
    () async {
      final service = _FakeAgentService()
        ..conversationSessions['codex'] = [
          _conversationSessionJson(
            id: 'native-codex-old',
            agentId: 'codex',
            text: 'Older native Codex history',
            updatedAt: '2026-06-12T00:00:01Z',
          ),
        ];
      final controller = FutureClientController(agentService: service);
      addTearDown(controller.dispose);

      controller.scannedTargets = [
        TargetCandidate(
          target: 'codex',
          label: 'Codex',
          kind: 'cli',
          status: 'detected',
          configured: false,
          confidence: 0.82,
          adapterStatus: 'implemented',
          adapterCapabilities: _parityReadyAdapterCapabilities,
          supportedActions: const ['runtime.message.send'],
        ),
      ];
      controller.selectedConversationAgentId = 'codex';
      await controller.loadConversationSessions('codex');

      expect(controller.selectedConversationSession?.id, 'native-codex-old');

      controller.startNewConversationSession();

      expect(controller.selectedConversationSessionId, isEmpty);
      expect(controller.selectedConversationSession, isNull);

      service.conversationSessions['codex'] = [
        _conversationSessionJson(
          id: 'native-codex-concurrent',
          agentId: 'codex',
          text: 'Concurrent native Codex history',
          updatedAt: '2026-06-15T00:00:01Z',
        ),
        _conversationSessionJson(
          id: 'native-codex-new',
          agentId: 'codex',
          text: 'Newer native Codex history',
          updatedAt: '2026-06-14T00:00:01Z',
        ),
        _conversationSessionJson(
          id: 'native-codex-old',
          agentId: 'codex',
          text: 'Older native Codex history',
          updatedAt: '2026-06-12T00:00:01Z',
        ),
      ];

      await controller.refreshConversationSessions('codex');

      expect(controller.selectedConversationSession, isNull);

      service.runtimeSessionIdResult = 'native-codex-new';
      await controller.sendConversationMessage('Fresh prompt');

      expect(service.lastRuntimeMessageRequest, {
        'agent': 'codex',
        'text': 'Fresh prompt',
        'workingDirectory': '/workspace/codex',
      });
      expect(controller.selectedConversationSession?.id, 'native-codex-new');
    },
  );

  test(
    'sendConversationMessage routes through runtime adapter without local append',
    () async {
      final service = _FakeAgentService()
        ..conversationSessions['codex'] = [
          _conversationSessionJson(
            id: 'native-codex-1',
            agentId: 'codex',
            text: 'Existing native Codex history',
          ),
        ];
      final controller = FutureClientController(agentService: service);
      addTearDown(controller.dispose);

      await controller.scanTargets();
      await controller.selectConversationAgent('codex');
      await controller.sendConversationMessage('  Hello Codex  ');

      expect(service.runtimeMessageCalls, 1);
      expect(service.lastRuntimeMessageRequest, {
        'agent': 'codex',
        'text': '  Hello Codex  ',
        'sessionId': 'native-codex-1',
        'sessionPath': '/tmp/codex/history.jsonl',
        'workingDirectory': '/workspace/codex',
        'binaryPath': ['', 'opt', 'lico-test', 'bin', 'codex'].join('/'),
      });
      expect(service.conversationAppendCalls, 0);
      expect(controller.selectedConversationSessions, hasLength(1));
      expect(controller.lastError, isEmpty);
      expect(controller.statusMessage, '已通过 Codex 运行时适配器发送消息。');
      controller.localePreference = 'en';
      expect(
        controller.displayStatusMessage,
        'Sent the message through the Codex runtime adapter.',
      );
    },
  );

  test(
    'sendConversationMessage uses the driver-owned native continuity id',
    () async {
      final service = _FakeAgentService()
        ..conversationSessions['codex'] = [
          _conversationSessionJson(
            id: 'codex-native-thread',
            agentId: 'codex',
            text: 'Existing native Codex history',
          ),
        ]
        ..runtimeSessionIdResult = 'codex-process-session'
        ..runtimeThreadIdResult = 'codex-native-thread'
        ..runtimeNativeSessionIdResult = 'codex-native-thread';
      final controller = FutureClientController(agentService: service);
      addTearDown(controller.dispose);

      await controller.scanTargets();
      await controller.selectConversationAgent('codex');
      await controller.sendConversationMessage('Continue the native thread');

      expect(service.runtimeMessageCalls, 1);
      expect(
        service.lastRuntimeMessageRequest['sessionId'],
        'codex-native-thread',
      );
      expect(controller.lastError, isEmpty);
      expect(
        controller.selectedConversationSession?.nativeSessionId,
        'codex-native-thread',
      );
    },
  );

  test('sendConversationMessage fails closed until parity is ready', () async {
    final service = _FakeAgentService()
      ..scanTargetsResult = [
        TargetCandidate(
          target: 'opencode',
          label: 'OpenCode',
          kind: 'cli',
          status: 'detected',
          configured: true,
          confidence: 0.9,
          adapterStatus: 'implemented',
          adapterCapabilities: const {
            'conversationDriver': 'implemented',
            'conversationProtocol': 'opencode-acp-v1-stdio-ndjson',
            'conversationReadiness': 'unverified',
            'conversationBlocker': 'live_release_parity_evidence_missing',
          },
          // A stale or malformed action projection must not bypass readiness.
          supportedActions: const ['runtime.message.send'],
        ),
      ];
    final controller = FutureClientController(agentService: service);
    addTearDown(controller.dispose);

    await controller.scanTargets();
    await controller.selectConversationAgent('opencode');
    await controller.sendConversationMessage('must not be sent');

    expect(service.runtimeMessageCalls, 0);
    expect(controller.lastError, 'live_release_parity_evidence_missing');
    expect(controller.statusMessage, contains('发送已禁用'));
  });

  test(
    'conversation composer forwards selected native model settings',
    () async {
      final service = _FakeAgentService()
        ..scanTargetsResult = [
          TargetCandidate(
            target: 'codex',
            label: 'Codex',
            kind: 'cli',
            status: 'detected',
            configured: true,
            confidence: 0.9,
            adapterStatus: 'implemented',
            modelCatalog: const {
              'status': 'available',
              'models': [
                {
                  'name': 'model-canary',
                  'reasoningEfforts': ['high'],
                },
              ],
            },
            adapterCapabilities: _parityReadyAdapterCapabilities,
            supportedActions: const ['runtime.message.send'],
          ),
        ];
      final controller = FutureClientController(agentService: service);
      addTearDown(controller.dispose);

      await controller.scanTargets();
      await controller.selectConversationAgent('codex');
      controller.selectConversationModel('model-canary');
      controller.selectConversationReasoningEffort('high');
      controller.startNewConversationSession();
      await controller.sendConversationMessage('settings parity canary');

      expect(service.runtimeMessageCalls, 1);
      expect(service.lastRuntimeMessageRequest['model'], 'model-canary');
      expect(service.lastRuntimeMessageRequest['reasoningEffort'], 'high');
    },
  );

  test(
    'sendConversationMessage never substitutes a projection session id',
    () async {
      final service = _FakeAgentService();
      final controller = FutureClientController(agentService: service);
      addTearDown(controller.dispose);

      await controller.scanTargets();
      controller.selectedConversationAgentId = 'codex';
      controller.selectedConversationSessionId = 'projection-only-id';
      controller.conversationSessionsByAgent = {
        'codex': const [
          AgentConversationSession(
            id: 'projection-only-id',
            nativeSessionId: '',
            agentId: 'codex',
            title: 'Read-only projection',
            createdAt: '2026-07-10T00:00:00Z',
            updatedAt: '2026-07-10T00:00:00Z',
            messages: [],
          ),
        ],
      };

      await controller.sendConversationMessage('do not fork this session');

      expect(service.runtimeMessageCalls, 0);
      expect(controller.lastError, 'native_session_id_missing');
    },
  );

  test(
    'sendConversationMessage never resumes the newest session for a stale selection',
    () async {
      final service = _FakeAgentService()
        ..conversationSessions['codex'] = [
          _conversationSessionJson(
            id: 'newer-concurrent-session',
            agentId: 'codex',
            text: 'A different native conversation',
          ),
        ];
      final controller = FutureClientController(agentService: service);
      addTearDown(controller.dispose);

      await controller.scanTargets();
      await controller.selectConversationAgent('codex');
      controller.selectedConversationSessionId = 'stale-deleted-session';

      await controller.sendConversationMessage(
        'must not resume another thread',
      );

      expect(service.runtimeMessageCalls, 0);
      expect(controller.lastError, 'native_session_unresolved');
    },
  );

  test(
    'send readback never falls back to the newest unrelated session',
    () async {
      final service = _FakeAgentService()
        ..conversationSessions['codex'] = [
          _conversationSessionJson(
            id: 'newest-unrelated-session',
            agentId: 'codex',
            text: 'Concurrent conversation',
          ),
        ]
        ..runtimeSessionIdResult = 'returned-session-not-yet-indexed';
      final controller = FutureClientController(agentService: service);
      addTearDown(controller.dispose);

      await controller.scanTargets();
      await controller.selectConversationAgent('codex');
      controller.startNewConversationSession();
      await controller.sendConversationMessage('create an exact new session');

      expect(service.runtimeMessageCalls, 1);
      expect(controller.selectedConversationSessionId, isNotEmpty);
      expect(controller.selectedConversationSession, isNull);
      expect(controller.lastError, 'native_session_readback_missing');

      await controller.sendConversationMessage('must not create a duplicate');

      expect(service.runtimeMessageCalls, 1);
      expect(controller.lastError, 'native_session_unresolved');

      service.conversationSessions['codex'] = [
        _conversationSessionJson(
          id: 'newest-unrelated-session',
          agentId: 'codex',
          text: 'Concurrent conversation',
        ),
        _conversationSessionJson(
          id: 'returned-session-projection',
          nativeSessionId: 'returned-session-not-yet-indexed',
          agentId: 'codex',
          text: 'Exact created conversation',
          updatedAt: '2026-07-10T00:00:01Z',
        ),
      ];
      await controller.refreshConversationSessions('codex');

      expect(
        controller.selectedConversationSession?.nativeSessionId,
        'returned-session-not-yet-indexed',
      );
    },
  );

  test(
    'default orchestration requires a configured policy before sending',
    () async {
      final service = _FakeAgentService()
        ..scanTargetsResult = [
          TargetCandidate(
            target: 'codex',
            label: 'Codex',
            kind: 'cli',
            status: 'detected',
            configured: true,
            confidence: 0.9,
            adapterStatus: 'implemented',
            adapterCapabilities: _parityReadyAdapterCapabilities,
            supportedActions: const ['runtime.message.send'],
          ),
        ];
      final controller = FutureClientController(agentService: service);
      addTearDown(controller.dispose);

      await controller.scanTargets();
      await controller.sendConversationMessage('Fix the failing tests');

      expect(
        controller.selectedConversationAgentId,
        agentOrchestrationTargetId,
      );
      expect(controller.agentOrchestrationPolicyConfigured, isFalse);
      expect(service.runtimeMessageCalls, 0);
      expect(controller.selectedConversationSession?.messages, isEmpty);
      expect(
        controller.lastError,
        'default orchestration policy not configured',
      );
      expect(controller.statusMessage, contains('未配置'));
    },
  );

  test(
    'default orchestration accepts commander-only policy and dispatches to it',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lico-commander-only-policy-',
      );
      addTearDown(() async {
        if (await directory.exists()) {
          await directory.delete(recursive: true);
        }
      });
      final service = _FakeAgentService()
        ..scanTargetsResult = [
          TargetCandidate(
            target: 'codex',
            label: 'Codex',
            kind: 'cli',
            status: 'detected',
            configured: true,
            confidence: 0.9,
            adapterStatus: 'implemented',
            modelCatalog: const {
              'status': 'available',
              'models': [
                {
                  'name': 'gpt-5.5',
                  'reasoningEfforts': ['high'],
                },
              ],
            },
            adapterCapabilities: _parityReadyAdapterCapabilities,
            supportedActions: const ['runtime.message.send'],
          ),
        ];
      final controller = FutureClientController(
        portableData: PortableDataRoot(dataDirectoryOverride: directory),
        agentService: service,
      );
      addTearDown(controller.dispose);

      await controller.scanTargets();
      await controller.saveAgentOrchestrationPolicy(
        const AgentOrchestrationPolicy(
          commanderAgentId: 'codex',
          commanderModelName: 'gpt-5.5',
          commanderReasoningEffort: 'high',
        ),
      );

      expect(controller.agentOrchestrationPolicyConfigured, isTrue);
      expect(controller.agentOrchestrationPolicy.modelLibrary, isEmpty);
      expect(controller.statusMessage, '默认编排策略已保存。');

      final plan = controller.previewAgentDispatchPlan('Fix the failing tests');
      expect(plan.blocked, isFalse);
      expect(plan.routes, hasLength(1));
      expect(plan.routes.single.agentId, 'codex');
      expect(plan.routes.single.modelName, 'gpt-5.5');
      expect(plan.routes.single.reasoningEffort, 'high');
      expect(plan.routes.single.coordinator, isTrue);

      await controller.sendConversationMessage('Fix the failing tests');

      expect(service.runtimeMessageCalls, 1);
      expect(service.lastRuntimeMessageRequest['agent'], 'codex');
      expect(service.lastRuntimeMessageRequest['model'], 'gpt-5.5');
      expect(service.lastRuntimeMessageRequest['reasoningEffort'], 'high');
      expect(controller.lastError, isEmpty);
    },
  );

  test(
    'persists default orchestration policy across controller initialize',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lico-orchestration-policy-',
      );
      addTearDown(() async {
        if (await directory.exists()) {
          await directory.delete(recursive: true);
        }
      });
      final targets = [
        TargetCandidate(
          target: 'codex',
          label: 'Codex',
          kind: 'cli',
          status: 'detected',
          configured: true,
          confidence: 0.9,
          adapterStatus: 'implemented',
          modelCatalog: const {
            'status': 'available',
            'models': [
              {
                'name': 'gpt-5.5',
                'reasoningEfforts': ['high'],
              },
            ],
          },
          adapterCapabilities: _parityReadyAdapterCapabilities,
          supportedActions: const ['runtime.message.send'],
        ),
        TargetCandidate(
          target: 'claude-code',
          label: 'Claude Code',
          kind: 'cli',
          status: 'detected',
          configured: true,
          confidence: 0.9,
          adapterStatus: 'implemented',
          modelCatalog: const {
            'status': 'available',
            'models': [
              {
                'name': 'deepseek-v4-flash',
                'reasoningEfforts': ['high'],
              },
            ],
          },
          adapterCapabilities: _parityReadyAdapterCapabilities,
          supportedActions: const ['runtime.message.send'],
        ),
      ];
      final portableData = PortableDataRoot(dataDirectoryOverride: directory);
      final controller = FutureClientController(
        portableData: portableData,
        agentService: _FakeAgentService()..scanTargetsResult = targets,
      );
      addTearDown(controller.dispose);

      await controller.scanTargets();
      await controller.saveAgentOrchestrationPolicy(
        AgentOrchestrationPolicy(
          label: 'Review Policy',
          commanderAgentId: 'codex',
          commanderModelName: 'gpt-5.5',
          commanderReasoningEffort: 'high',
          modelLibrary: const [
            AgentModelLibraryEntry(
              agentId: 'codex',
              modelName: 'gpt-5.5',
              reasoningEffort: 'high',
            ),
            AgentModelLibraryEntry(
              agentId: 'claude-code',
              modelName: 'deepseek-v4-flash',
              reasoningEffort: 'high',
            ),
          ]
        ),
      );

      final policyFile = File(
        p.join(
          directory.path,
          'future-client',
          'agent-orchestration-policy.json',
        ),
      );
      expect(await policyFile.exists(), isTrue);

      final reloaded = FutureClientController(
        portableData: PortableDataRoot(dataDirectoryOverride: directory),
        agentService: _FakeAgentService()..scanTargetsResult = targets,
      );
      addTearDown(reloaded.dispose);

      await reloaded.initialize();

      expect(reloaded.agentOrchestrationPolicyConfigured, isTrue);
      expect(reloaded.agentOrchestrationPolicy.label, 'Review Policy');
      expect(reloaded.agentOrchestrationPolicy.commanderAgentId, 'codex');
      expect(reloaded.agentOrchestrationPolicy.commanderModelName, 'gpt-5.5');
      expect(
        reloaded.agentOrchestrationPolicy.commanderReasoningEffort,
        'high',
      );
      expect(reloaded.agentOrchestrationPolicy.modelLibrary.map((e) => e.key), [
        const AgentModelLibraryEntry(
          agentId: 'codex',
          modelName: 'gpt-5.5',
          reasoningEffort: 'high',
        ).key,
        const AgentModelLibraryEntry(
          agentId: 'claude-code',
          modelName: 'deepseek-v4-flash',
          reasoningEffort: 'high',
        ).key,
      ]);
    },
  );

  test(
    'default orchestration falls back and circuit-breaks quota exhausted routes',
    () async {
      final service = _FakeAgentService()
        ..scanTargetsResult = [
          TargetCandidate(
            target: 'codex',
            label: 'Codex',
            kind: 'cli',
            status: 'detected',
            configured: true,
            confidence: 0.9,
            adapterStatus: 'implemented',
            modelCatalog: const {
              'status': 'available',
              'models': [
                {
                  'name': 'gpt-5.5',
                  'reasoningEfforts': ['high'],
                },
              ],
            },
            adapterCapabilities: _parityReadyAdapterCapabilities,
            supportedActions: const ['runtime.message.send'],
          ),
          TargetCandidate(
            target: 'claude-code',
            label: 'Claude Code',
            kind: 'cli',
            status: 'detected',
            configured: true,
            confidence: 0.9,
            adapterStatus: 'implemented',
            modelCatalog: const {
              'status': 'available',
              'models': [
                {
                  'providerId': 'deepseek',
                  'provider': 'DeepSeek',
                  'name': 'deepseek-v4-flash',
                  'reasoningEfforts': ['high'],
                },
              ],
            },
            adapterCapabilities: _parityReadyAdapterCapabilities,
            supportedActions: const ['runtime.message.send'],
          ),
          TargetCandidate(
            target: 'opencode',
            label: 'OpenCode',
            kind: 'cli',
            status: 'detected',
            configured: true,
            confidence: 0.9,
            adapterStatus: 'implemented',
            adapterCapabilities: _parityReadyAdapterCapabilities,
            supportedActions: const ['runtime.message.send'],
          ),
        ];
      final controller = FutureClientController(agentService: service);
      addTearDown(controller.dispose);

      await controller.scanTargets();
      controller.agentOrchestrationPolicy = AgentOrchestrationPolicy(
        commanderAgentId: 'codex',
        commanderModelName: 'gpt-5.5',
        commanderReasoningEffort: 'high',
        modelLibrary: [
          AgentModelLibraryEntry(
            agentId: 'codex',
            modelName: 'gpt-5.5',
            reasoningEffort: 'high',
          ),
          AgentModelLibraryEntry(
            agentId: 'claude-code',
            modelName: 'deepseek-v4-flash',
            reasoningEffort: 'high',
          ),
        ],
      );
      controller.agentAllowanceOverrides = const {
        'codex': [
          AgentUsageAllowance(
            kind: 'quota',
            label: 'Codex quota',
            provider: 'codex',
            period: 'session',
            status: 'exhausted',
            value: '0',
            unit: 'requests',
            source: 'test',
            message: 'No quota',
          ),
        ],
      };

      await controller.sendConversationMessage('Fix the failing tests');

      expect(service.runtimeMessageCalls, 1);
      expect(service.runtimeMessageRequests.single['agent'], 'claude-code');
      expect(
        service.runtimeMessageRequests.single['text'],
        contains('Fix the failing tests'),
      );
      expect(
        service.runtimeMessageRequests.single['text'],
        contains('模型：deepseek-v4-flash'),
      );
      expect(
        service.runtimeMessageRequests.single['text'],
        contains('指挥官：Codex / gpt-5.5 / 思考强度：高'),
      );
      expect(service.runtimeMessageRequests.single['text'], contains('思考强度：高'));
      expect(
        service.runtimeMessageRequests.single['model'],
        'deepseek-v4-flash',
      );
      expect(service.runtimeMessageRequests.single['reasoningEffort'], 'high');
      expect(
        controller.agentOrchestrationCircuitBrokenAgentIds,
        contains('codex'),
      );
      expect(
        controller.selectedConversationAgentId,
        agentOrchestrationTargetId,
      );
      expect(
        controller.selectedConversationSession?.messages.last.text,
        contains('Codex: 额度不足'),
      );
      expect(
        controller.selectedConversationSession?.messages.last.text,
        contains('Claude Code'),
      );
    },
  );

  test(
    'archiveConversationKeywords creates native job and observes completion',
    () async {
      final service = _FakeAgentService()
        ..archiveJobDrainGate = Completer<void>();
      final controller = FutureClientController(agentService: service);
      addTearDown(controller.dispose);

      await controller.archiveConversationKeywords(
        keywords: '  Pact, Pactium  ',
        path: ' /tmp/pactium ',
      );

      expect(service.scanTargetsCalls, 0);
      expect(service.archiveJobCreateCalls, 1);
      expect(service.archiveJobDrainCalls, 1);
      expect(
        service.cliCalls.any(
          (args) =>
              args.length >= 3 &&
              args[0] == 'snapshots' &&
              args[1] == 'archive' &&
              args[2] == 'collect',
        ),
        isFalse,
      );
      expect(service.archivedKeywords, 'Pact, Pactium');
      expect(service.archiveDestinationPath, '/tmp/pactium');
      expect(controller.isCollectingConversationArchive, isTrue);
      expect(controller.selectedConversationArchiveJobId, 'archive-job-1');
      expect(controller.conversationArchiveResult?['status'], 'queued');
      expect(
        controller.conversationArchiveResult?['targetScan']?['clientCount'],
        1,
      );
      expect(controller.statusMessage, '已创建本机归档任务，扫描 1 个目标，1 个可用，正在运行。');

      service.archiveJobDrainGate!.complete();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(service.archiveJobStatusCalls, 1);
      expect(service.archiveJobEventsCalls, 1);
      expect(controller.conversationArchiveResult?['status'], 'completed');
      expect(
        controller.conversationArchiveResult?['workflow']?['status'],
        'completed',
      );
      expect(controller.conversationSnapshotCollections, hasLength(1));
      expect(controller.isCollectingConversationArchive, isFalse);
      expect(controller.statusMessage, '已归档 2 条原生对话到目录，本机校验 ok。');
      expect(controller.statusCaption, '/tmp/pactium');
    },
  );

  test(
    'archiveSelectedConversationAgent writes into agent subdirectory',
    () async {
      final service = _FakeAgentService()
        ..archiveJobDrainGate = Completer<void>();
      final controller = FutureClientController(agentService: service);
      addTearDown(controller.dispose);

      controller.scannedTargets = [_agentArchiveTarget()];
      controller.selectedConversationAgentId = 'claude-code';
      controller.archiveDestinationController.text = '/tmp/native-archive';

      await controller.archiveSelectedConversationAgent();

      expect(service.archiveJobCreateCalls, 1);
      expect(service.archiveJobDrainCalls, 1);
      expect(service.archivedKeywords, 'claude-code');
      expect(
        service.archiveDestinationPath,
        p.join('/tmp/native-archive', 'claude-code'),
      );
      expect(controller.isCollectingConversationArchive, isTrue);

      service.archiveJobDrainGate!.complete();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
    },
  );

  test(
    'archiveSelectedConversationAgent requires settings archive path',
    () async {
      final service = _FakeAgentService();
      final controller = FutureClientController(agentService: service);
      addTearDown(controller.dispose);

      controller.scannedTargets = [_agentArchiveTarget()];
      controller.selectedConversationAgentId = 'claude-code';

      await controller.archiveSelectedConversationAgent();

      expect(service.archiveJobCreateCalls, 0);
      expect(controller.statusMessage, '请先在设置中指定对话归档目录。');
      expect(controller.statusCaption, 'Agent archive');
    },
  );

  test('archive retry events are surfaced from native job events', () async {
    final service = _FakeAgentService()..archiveJobAttempt = 2;
    final controller = FutureClientController(agentService: service);
    addTearDown(controller.dispose);

    await controller.archiveConversationKeywords(
      keywords: 'Pactium',
      path: '/tmp/pactium',
    );
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(service.archiveVerifyCalls, 0);
    expect(service.archiveJobDrainCalls, 1);
    expect(
      controller.conversationArchiveResult?['workflow']?['status'],
      'completed',
    );
    expect(controller.conversationArchiveResult?['workflow']?['attempt'], 2);
    expect(
      controller.conversationArchiveWorkflowEvents.any(
        (event) =>
            event['type'] == 'archive.retry.scheduled' &&
            event['status'] == 'retry_scheduled',
      ),
      isTrue,
    );
    expect(
      controller.conversationArchiveResult?['validation']?['healthStatus'],
      'ok',
    );
  });

  test(
    'snapshot root settings and bridge ensure call snapshot CLI surface',
    () async {
      final service = _FakeAgentService();
      final controller = FutureClientController(agentService: service);
      addTearDown(controller.dispose);

      await controller.refreshConversationSnapshotRoot();
      expect(controller.snapshotRootController.text, service.snapshotRootPath);

      await controller.setConversationSnapshotRoot('/tmp/native-archive');
      expect(service.snapshotRootSetCalls, 1);
      expect(controller.snapshotRootController.text, '/tmp/native-archive');

      service.preferredSnapshotCuratorTarget = 'codex';
      await controller.refreshPreferredSnapshotCurator();
      expect(service.snapshotCuratorGetCalls, 1);
      expect(controller.snapshotCuratorController.text, 'codex');

      await controller.setPreferredSnapshotCurator('opencode');
      expect(service.snapshotCuratorSetCalls, 1);
      expect(service.preferredSnapshotCuratorTarget, 'opencode');
      expect(controller.snapshotCuratorController.text, 'opencode');

      await controller.setPreferredSnapshotCurator('   ');
      expect(service.snapshotCuratorSetCalls, 2);
      expect(service.preferredSnapshotCuratorTarget, isEmpty);
      expect(controller.snapshotCuratorController.text, isEmpty);

      await controller.scanTargets();
      await controller.selectConversationAgent('codex');
      await controller.ensureSnapshotBridgeForSelectedAgent();
      expect(service.snapshotBridgeEnsureCalls, 1);
      expect(service.ensuredBridgeTarget, 'codex');
      expect(controller.conversationArchiveResult?['status'], 'verified');
    },
  );

  test('archive profile actions update controller health state', () async {
    final service = _FakeAgentService();
    final controller = FutureClientController(agentService: service);
    addTearDown(controller.dispose);

    await controller.refreshConversationArchiveProfiles();
    expect(service.archiveProfilesListCalls, 1);
    expect(controller.conversationArchiveProfiles, hasLength(1));
    expect(controller.selectedArchiveProfileId, 'licolite');

    await controller.runSelectedConversationArchiveProfile();
    expect(service.archiveRunCalls, 1);
    expect(service.archiveProfileId, 'licolite');
    expect(
      controller.conversationArchiveResult?['mode'],
      'conversation-archive',
    );
    expect(
      controller.conversationArchiveReport?['validation']['healthStatus'],
      'ok',
    );
    expect(controller.statusMessage, '项目归档完成：2 条，健康状态 ok。');

    await controller.verifySelectedConversationArchiveProfile();
    expect(service.archiveVerifyCalls, 1);
    expect(
      controller.conversationArchiveReport?['mode'],
      'conversation-archive-verify',
    );

    await controller.reportSelectedConversationArchiveProfile();
    expect(service.archiveReportCalls, 1);
    expect(
      controller.conversationArchiveReport?['mode'],
      'conversation-archive-report',
    );
  });

  test('inspect target captures failures', () async {
    final service = _FakeAgentService()..throwInspectTarget = true;
    final controller = FutureClientController(agentService: service);
    addTearDown(controller.dispose);

    await controller.inspectTarget('codex');

    expect(controller.lastError, contains('inspect failed'));
    expect(controller.statusMessage, 'codex 目标适配器读取失败。');
  });

  test('inspect target success updates status and result', () async {
    final service = _FakeAgentService();
    final controller = FutureClientController(agentService: service);
    addTearDown(controller.dispose);

    await controller.inspectTarget('codex');

    expect(controller.targetInspection, {'target': 'codex'});
    expect(controller.statusMessage, '已读取 codex 目标适配器。');
    expect(controller.statusCaption, 'Target inspect');
  });

  test(
    'adds manual target using trimmed input and ignores empty names',
    () async {
      final service = _FakeAgentService();
      final controller = FutureClientController(agentService: service);
      addTearDown(controller.dispose);

      await controller.addManualTarget(
        target: '  openclaw  ',
        configPath: ' /tmp/openclaw.json ',
        historyRoot: ' /tmp/openclaw-history ',
      );
      expect(service.addedTarget, 'openclaw');
      expect(service.addedConfigPath, '/tmp/openclaw.json');
      expect(service.addedHistoryRoot, '/tmp/openclaw-history');
      expect(service.scanTargetsCalls, 2);
      expect(controller.statusMessage, contains('已添加 openclaw 手动目标。'));

      service.scanTargetsCalls = 0;
      await controller.addManualTarget(target: '   ');
      expect(service.scanTargetsCalls, 0);
      expect(controller.lastError, isEmpty);
    },
  );

  test('adds manual target failure keeps error state', () async {
    final service = _FakeAgentService()..throwAddTarget = true;
    final controller = FutureClientController(agentService: service);
    addTearDown(controller.dispose);

    await controller.addManualTarget(
      target: 'openclaw',
      configPath: ' /tmp/openclaw.json ',
    );

    expect(controller.lastError, contains('add failed'));
    expect(controller.statusMessage, 'openclaw 手动目标添加失败。');
    expect(controller.statusCaption, 'Targets');
  });

  test('constructs with default dependencies', () {
    final controller = FutureClientController();
    addTearDown(controller.dispose);

    expect(controller.agentService, isA<AgentService>());
    expect(controller.portableData, isA<PortableDataRoot>());
  });

  test(
    'restores snapshots successfully and ignores blank snapshot ids',
    () async {
      final service = _FakeAgentService();
      final controller = FutureClientController(agentService: service);
      addTearDown(controller.dispose);

      await controller.restoreSnapshot('snapshot-codex-1');
      expect(service.restoredSnapshotId, 'snapshot-codex-1');
      expect(controller.snapshotRestoreResult?['ok'], isTrue);

      await controller.restoreSnapshot('   ');
      expect(service.restoreSnapshotCount, 1);
    },
  );

  test('restores snapshot handles client failure', () async {
    final service = _FakeAgentService()..throwRestoreSnapshot = true;
    final controller = FutureClientController(agentService: service);
    addTearDown(controller.dispose);

    await controller.restoreSnapshot('snapshot-codex-1');

    expect(controller.lastError, contains('restore failed'));
    expect(controller.statusMessage, '配置快照恢复失败。');
  });

  test('plans target config and propagates client failure', () async {
    final service = _FakeAgentService();
    final controller = FutureClientController(agentService: service);
    addTearDown(controller.dispose);

    await controller.planTargetConfig('codex');
    expect(controller.targetConfigPlan, isNotNull);
    expect(controller.statusMessage, contains('已生成 codex MCP 配置计划。'));

    service.throwPlanTargetConfig = true;
    await controller.planTargetConfig('codex');
    expect(controller.lastError, contains('plan failed'));
    expect(controller.statusMessage, 'codex MCP 配置计划生成失败。');
  });

  test('supports MCP plugin status, update, and rollback', () async {
    final service = _FakeAgentService();
    final controller = FutureClientController(agentService: service);
    addTearDown(controller.dispose);

    await controller.scanTargets();
    final target = controller.scannedTargets.single;

    await controller.refreshMcpPluginStatus(target);
    expect(controller.mcpPluginStatuses[target.target], isNotNull);

    await controller.updateMcpPlugin(target);
    expect(service.updatedPluginTarget, 'codex');
    expect(controller.mcpPluginActionResult?['status'], 'updated');

    await controller.rollbackLatestMcpPlugin(target);
    expect(service.rolledBackSnapshotId, 'snapshot-codex-1');
    expect(controller.mcpPluginActionResult?['status'], 'rolled_back');
  });

  test('MCP rollback fails when no snapshot is available', () async {
    final service = _FakeAgentService()..snapshots = const [];
    final controller = FutureClientController(agentService: service);
    addTearDown(controller.dispose);

    await controller.scanTargets();
    final target = controller.scannedTargets.single;

    await controller.rollbackLatestMcpPlugin(target);
    expect(controller.lastError, contains('No snapshot found'));
    expect(controller.mcpPluginActionResult, isNull);
    expect(controller.statusMessage, '${target.label} LicoLite MCP 插件回滚失败。');
  });

  test('blocks duplicated MCP action calls while one is running', () async {
    final service = _FakeAgentService()..mcpUpdateGate = Completer<void>();
    final controller = FutureClientController(agentService: service);
    addTearDown(controller.dispose);

    await controller.scanTargets();
    final target = controller.scannedTargets.single;

    unawaited(controller.updateMcpPlugin(target));
    await Future<void>.delayed(Duration.zero);

    await controller.updateMcpPlugin(target);
    expect(service.updateMcpCalls, 1);

    service.mcpUpdateGate!.complete();
    await Future<void>.delayed(Duration.zero);
    expect(controller.isMcpPluginBusy(target.target), isFalse);
  });

  test('supports skill hub state machine and busy lock', () async {
    final service = _FakeAgentService();
    final controller = FutureClientController(agentService: service);
    addTearDown(controller.dispose);

    await controller.requestSkillHubPairing('codex', target: 'manual');
    await controller.approveSkillHubPairing('codex');
    await controller.refreshSkillHub('codex');

    expect(controller.skillHubPairings, hasLength(1));
    expect(controller.skillHubSkills, hasLength(1));
    expect(controller.skillHubActionResult?['agent'], 'codex');

    await controller.revokeSkillHubPairing('codex');
    expect(controller.skillHubSkills, isEmpty);

    service.skillBusyGate = Completer<void>();
    unawaited(controller.refreshSkillHub('codex'));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await controller.refreshSkillHub('codex');
    expect(service.listPairingsCalls, greaterThanOrEqualTo(5));
    expect(service.listSkillsCalls, greaterThanOrEqualTo(3));
    service.skillBusyGate!.complete();
    await Future<void>.delayed(Duration.zero);
  });

  test('reports skill hub action failures', () async {
    final service = _FakeAgentService()..throwListPairings = true;
    final controller = FutureClientController(agentService: service);
    addTearDown(controller.dispose);

    await controller.refreshSkillHub('codex');

    expect(controller.lastError, contains('listPairings failed'));
    expect(controller.statusMessage, '技能中心操作失败。');
    controller.localePreference = 'en';
    expect(controller.displayStatusMessage, 'The Skill Hub operation failed.');
    expect(controller.isSkillHubBusy, isFalse);
  });

  test('supports GitHub skill install preview apply and rollback', () async {
    final service = _FakeAgentService()..skills = const [];
    final controller = FutureClientController(agentService: service);
    addTearDown(controller.dispose);

    await controller.previewSkillInstall(
      agent: 'codex',
      url: 'https://github.com/example/skills/tree/main/review-helper',
      installRoot: '/tmp/codex-skills',
      name: 'review-helper',
      overwrite: true,
    );

    expect(service.planSkillInstallCalls, 1);
    expect(service.installedSkillAgent, 'codex');
    expect(service.installedSkillUrl, contains('github.com/example/skills'));
    expect(service.installedSkillRoot, '/tmp/codex-skills');
    expect(service.installedSkillName, 'review-helper');
    expect(service.installedSkillOverwrite, isTrue);
    expect(controller.skillInstallPlan?['status'], 'planned');

    await controller.installSkillFromGitHub(
      agent: 'codex',
      url: 'https://github.com/example/skills/tree/main/review-helper',
      installRoot: '/tmp/codex-skills',
      name: 'review-helper',
      overwrite: true,
      pin: true,
    );

    expect(service.applySkillInstallCalls, 1);
    expect(service.installedSkillPin, isTrue);
    expect(controller.skillInstallResult?['status'], 'installed');
    expect(controller.skillHubSkills.single['skillId'], 'review-helper');

    await controller.rollbackSkillInstall(
      agent: 'codex',
      snapshotId: 'skill-install-snapshot-1',
    );

    expect(service.rollbackSkillInstallCalls, 1);
    expect(
      service.rolledBackSkillInstallSnapshotId,
      'skill-install-snapshot-1',
    );
    expect(controller.skillInstallResult?['status'], 'rolled_back');
    expect(controller.skillHubSkills, isEmpty);
  });

  test('creates mobile pairing and records secure relay delivery', () async {
    final directory = await Directory.systemTemp.createTemp(
      'lico-mobile-chat-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final agentService = _FakeAgentService()
      ..conversationSessions['codex'] = [
        _conversationSessionJson(
          id: 'native-phone-list',
          agentId: 'codex',
          text: 'From native history',
        ),
      ];
    final relayService = _FakeMobileRelayService()
      ..queuedCommands = [
        const MobileRelayCommand(
          commandId: 'cmd-1',
          type: 'secure_mesh.envelope',
          payload: {},
          status: 'pending',
          createdAt: '2026-06-12T00:00:00.000Z',
        ),
      ];
    final controller = FutureClientController(
      portableData: PortableDataRoot(dataDirectoryOverride: directory),
      agentService: agentService,
      mobileRelayService: relayService,
    );
    addTearDown(controller.dispose);

    await controller.initialize();
    await controller.scanTargets();
    await controller.createMobilePairing();

    expect(relayService.secureMeshStatusCalls, 0);
    expect(relayService.createPairingCalls, 1);
    expect(controller.mobileRelayActionResult?['pairingCode'], '1234-5678');
    expect(controller.mobilePairingPresentation?.pairingCode, '1234-5678');
    expect(
      controller.mobilePairingPresentation?.inviteText,
      startsWith('licoarc://pair?invite='),
    );
    expect(controller.mobileRelayConfig.lastPairingCode, isEmpty);
    expect(controller.mobileRelayConfig.hasPairing, isTrue);

    await controller.pollMobileRelayOnce();

    expect(relayService.syncCalls, 1);
    expect(relayService.syncAllowInteractionFlags, [isFalse]);
    expect(
      controller.lastMobileRelayCommands.single.type,
      'secure_mesh.envelope',
    );
  });

  test('completes mobile OAuth callback from clipboard service', () async {
    final directory = await Directory.systemTemp.createTemp(
      'lico-mobile-oauth-clipboard-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final relayService = _FakeMobileRelayService();
    final clipboard = _FakeClipboardService(
      'licoarc://oauth/callback?code=callback-code',
    );
    final controller = FutureClientController(
      portableData: PortableDataRoot(dataDirectoryOverride: directory),
      agentService: _FakeAgentService(),
      mobileRelayService: relayService,
      clientClipboardService: clipboard,
      mobileClientRuntimePlatformOverride: true,
    );
    addTearDown(controller.dispose);

    await controller.initialize();
    await controller.addMobileAgentProvider('chatgpt');
    final account = controller.mobileAgentAccounts.singleWhere(
      (account) => account.providerId == 'chatgpt',
    );

    await controller.completeMobileAgentOAuthCallbackFromClipboard(
      'chatgpt',
      mobileAccountId: account.id,
    );

    expect(clipboard.readCalls, 1);
    expect(relayService.completeOAuthCallbackCalls, 1);
    expect(relayService.lastProviderId, 'chatgpt');
    expect(relayService.lastMobileAccountId, account.id);
    expect(
      relayService.lastOAuthCallbackUrl,
      'licoarc://oauth/callback?code=callback-code',
    );
    expect(controller.lastError, isEmpty);
  });

  test('mobile relay empty background poll keeps current status', () async {
    final directory = await Directory.systemTemp.createTemp(
      'lico-mobile-empty-sync-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final relayService = _FakeMobileRelayService();
    final controller = FutureClientController(
      portableData: PortableDataRoot(dataDirectoryOverride: directory),
      agentService: _FakeAgentService(),
      mobileRelayService: relayService,
    );
    addTearDown(controller.dispose);

    await controller.initialize();
    await controller.createMobilePairing();

    final previousMessage = controller.statusMessage;
    final previousCaption = controller.statusCaption;
    await controller.pollMobileRelayOnce();

    expect(relayService.syncCalls, 1);
    expect(controller.statusMessage, previousMessage);
    expect(controller.statusCaption, previousCaption);
    expect(controller.statusMessage, isNot('正在同步手机中转命令。'));
    expect(controller.statusMessage, isNot('手机中转已同步，暂无新命令。'));
  });

  test(
    'mobile relay authorization-required background poll pauses until manual sync',
    () async {
      final relayService = _FakeMobileRelayService()
        ..syncError = const LicoClientRpcException('authorization_required');
      final controller = FutureClientController(
        agentService: _FakeAgentService(),
        mobileRelayService: relayService,
      );
      addTearDown(controller.dispose);

      await controller.initialize();
      await controller.createMobilePairing();
      await controller.pollMobileRelayOnce();
      await controller.pollMobileRelayOnce();

      expect(relayService.syncCalls, 1);
      expect(relayService.syncAllowInteractionFlags, [isFalse]);
      expect(controller.statusMessage, contains('等待本机授权'));

      relayService.syncError = null;
      await controller.pollMobileRelayOnce(showProgress: true);

      expect(relayService.syncCalls, 2);
      expect(relayService.syncAllowInteractionFlags, [isFalse, isTrue]);
      expect(controller.lastError, isEmpty);
    },
  );

  test('claims mobile pairing from compact invite token', () async {
    final relayService = _FakeMobileRelayService();
    final controller = FutureClientController(
      agentService: _FakeAgentService(),
      mobileRelayService: relayService,
    );
    addTearDown(controller.dispose);

    final invite = {
      'gatewayUrl': 'https://api.licolite.app',
      'pairingId': 'pair-1',
      'pairingCode': '1234-5678',
      'pcClientId': 'pc-1',
      'pcClientName': 'Mac Studio',
      'pcSecureMesh': {'endpointId': 'pc-1'},
      'e2eePairingSecret': 'secret',
    };
    final token = base64Url
        .encode(utf8.encode(jsonEncode(invite)))
        .replaceAll('=', '');

    await controller.claimMobilePairingInvite('licoarc://pair?invite=$token');

    expect(relayService.claimPairingCalls, 1);
    expect(relayService.lastPairingInvite?['pairingId'], 'pair-1');
    expect(controller.mobileRelayConfig.paired, isTrue);
    expect(controller.scannedTargets.single.target, 'codex');
    expect(controller.selectedConversationAgentId, agentOrchestrationTargetId);
  });

  test(
    'claiming mobile pairing refreshes DeepSeek provider and marks it authorized locally',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lico-mobile-claim-deepseek-sync-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final relayService = _FakeMobileRelayService()
        ..authorizedProvidersOnRefresh = const [
          MobileRelayAuthorizedProvider(
            providerId: 'deepseek',
            label: 'DeepSeek',
            credentialPresent: true,
            profileId: 'deepseek-default',
            source: 'desktop-model-profile',
          ),
        ];
      final controller = FutureClientController(
        portableData: PortableDataRoot(dataDirectoryOverride: directory),
        agentService: _FakeAgentService(),
        mobileRelayService: relayService,
        mobileClientRuntimePlatformOverride: true,
      );
      addTearDown(controller.dispose);

      final invite = {
        'gatewayUrl': 'https://api.licolite.app',
        'pairingId': 'pair-1',
        'pairingCode': '1234-5678',
        'pcClientId': 'pc-1',
        'pcClientName': 'ARC Desktop',
        'pcSecureMesh': {'endpointId': 'pc-1'},
        'e2eePairingSecret': 'secret',
      };
      final token = base64Url
          .encode(utf8.encode(jsonEncode(invite)))
          .replaceAll('=', '');

      await controller.claimMobilePairingInvite('licoarc://pair?invite=$token');

      expect(relayService.claimPairingCalls, 1);
      expect(relayService.refreshPairingStatusCalls, 1);
      expect(relayService.credentialSyncCalls, 1);
      expect(relayService.credentialSyncProfileIds, ['deepseek-default']);
      final synced = controller.mobileAgentAccounts.singleWhere(
        (account) =>
            account.providerId == 'deepseek' && account.usesMobileSynced,
      );
      expect(synced.credentialPresent, isTrue);
      expect(synced.usesDesktopRelay, isFalse);
      expect(synced.relayDeviceLabel, 'ARC Desktop');
      expect(synced.relayProfileId, 'deepseek-default');
      expect(
        controller.mobileAgentAccounts.any((account) {
          return account.providerId == 'deepseek' &&
              account.usesDesktopRelay &&
              account.credentialPresent;
        }),
        isTrue,
      );
    },
  );

  test('refreshes secure mesh status for the relay adapter panel', () async {
    final directory = await Directory.systemTemp.createTemp(
      'lico-secure-mesh-status-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final relayService = _FakeMobileRelayService();
    final controller = FutureClientController(
      portableData: PortableDataRoot(dataDirectoryOverride: directory),
      agentService: _FakeAgentService(),
      mobileRelayService: relayService,
    );
    addTearDown(controller.dispose);

    await controller.initialize();
    await controller.refreshSecureMeshStatus();

    expect(relayService.secureMeshStatusCalls, 1);
    expect(relayService.secureMeshStatusAuthorizeFlags, [true]);
    expect(
      controller.secureMeshStatus?['cryptoCoreStatus'],
      'blocked_for_production',
    );
    expect(controller.statusCaption, 'Secure Mesh');
  });

  test(
    'evaluates secure mesh device trust policy for the relay panel',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lico-secure-mesh-trust-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final relayService = _FakeMobileRelayService();
      final controller = FutureClientController(
        portableData: PortableDataRoot(dataDirectoryOverride: directory),
        agentService: _FakeAgentService(),
        mobileRelayService: relayService,
      );
      addTearDown(controller.dispose);

      await controller.evaluateSecureMeshDeviceTrustPolicy(
        identity: const {
          'endpointId': 'pc-a',
          'identityPublicKey': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          'signingPublicKey': 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
          'rotationEpoch': 1,
        },
        trustState: 'verified',
      );

      expect(relayService.deviceTrustEvaluateCalls, 1);
      expect(relayService.lastDeviceTrustIdentity?['endpointId'], 'pc-a');
      expect(
        controller.secureMeshDeviceTrustPolicy?['trustState'],
        'unverified',
      );
      expect(
        controller.secureMeshDeviceTrustPolicy?['requestedTrustState'],
        'verified',
      );
      expect(
        controller.secureMeshDeviceTrustPolicy?['decision']?['code'],
        'verification_required',
      );
      expect(controller.statusMessage, 'Secure Mesh 设备信任策略已评估。');
    },
  );

  test('evaluates secure mesh file route for the relay panel', () async {
    final directory = await Directory.systemTemp.createTemp(
      'lico-secure-mesh-file-route-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final relayService = _FakeMobileRelayService();
    final controller = FutureClientController(
      portableData: PortableDataRoot(dataDirectoryOverride: directory),
      agentService: _FakeAgentService(),
      mobileRelayService: relayService,
    );
    addTearDown(controller.dispose);

    await controller.evaluateSecureMeshFileRoute(
      manifest: const {
        'fileId': 'file-a',
        'fileName': 'launch-plan.pdf',
        'mimeType': 'application/pdf',
        'relativePath': 'workspace/reports',
        'totalSize': 16,
        'chunkSize': 8,
        'chunkCount': 2,
      },
    );

    expect(relayService.fileRouteEvaluateCalls, 1);
    expect(relayService.lastFileRouteManifest?['fileId'], 'file-a');
    expect(
      controller.secureMeshFileRoute?['route']?['uploadOperation'],
      'secure_mesh.file_chunk.upload',
    );
    expect(controller.statusMessage, 'Secure Mesh 文件路由已评估。');
  });

  test(
    'evaluates secure mesh file receive destination for the relay panel',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lico-secure-mesh-file-receive-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final relayService = _FakeMobileRelayService();
      final controller = FutureClientController(
        portableData: PortableDataRoot(dataDirectoryOverride: directory),
        agentService: _FakeAgentService(),
        mobileRelayService: relayService,
      );
      controller.localePreference = 'zh';
      addTearDown(controller.dispose);

      await controller.evaluateSecureMeshFileReceiveDestination(
        manifest: const {
          'fileId': 'file-a',
          'fileName': 'launch-plan.pdf',
          'mimeType': 'application/pdf',
          'relativePath': 'workspace/reports',
          'totalSize': 16,
          'chunkSize': 8,
          'chunkCount': 2,
        },
        approvedRoot: '/tmp/approved-root',
      );

      expect(relayService.fileReceiveDestinationEvaluateCalls, 1);
      expect(
        relayService.lastFileReceiveDestinationManifest?['fileId'],
        'file-a',
      );
      expect(relayService.lastApprovedRoot, '/tmp/approved-root');
      expect(
        controller
            .secureMeshFileReceiveDestination?['receivePolicy']?['writeOperation'],
        'secure_mesh.file_receive.write',
      );
      expect(controller.statusMessage, '安全网格文件接收位置已评估。');
    },
  );

  test(
    'mobile relay secure envelope does not expose command body to GUI',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lico-mobile-runtime-chat-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final agentService = _FakeAgentService()
        ..conversationSessions['codex'] = [
          _conversationSessionJson(
            id: 'native-phone-runtime',
            agentId: 'codex',
            text: 'After phone runtime send',
          ),
        ];
      final relayService = _FakeMobileRelayService()
        ..queuedCommands = [
          const MobileRelayCommand(
            commandId: 'cmd-runtime-1',
            type: 'secure_mesh.envelope',
            payload: {},
            status: 'pending',
            createdAt: '2026-06-12T00:00:00.000Z',
          ),
        ];
      final controller = FutureClientController(
        portableData: PortableDataRoot(dataDirectoryOverride: directory),
        agentService: agentService,
        mobileRelayService: relayService,
      );
      addTearDown(controller.dispose);

      await controller.initialize();
      await controller.createMobilePairing();
      await controller.pollMobileRelayOnce();

      expect(relayService.syncCalls, 1);
      expect(
        controller.lastMobileRelayCommands.single.type,
        'secure_mesh.envelope',
      );
    },
  );

  test('mobile initialize defers paired computer target refresh', () async {
    final directory = await Directory.systemTemp.createTemp(
      'lico-mobile-relay-targets-',
    );
    addTearDown(() => _deleteTempDirectory(directory));
    final relayService = _FakeMobileRelayService()
      ..config = MobileRelayConfig.defaults().copyWith(
        pairingId: 'pair-1',
        pcClientId: 'pc-1',
        pcClientName: 'MacBook Pro',
        mobileToken: 'mobile-token',
        mobileTokenPresent: true,
        paired: true,
        relayEnabled: false,
      );
    final controller = FutureClientController(
      portableData: PortableDataRoot(dataDirectoryOverride: directory),
      agentService: _FakeAgentService(),
      mobileRelayService: relayService,
      mobileClientRuntimePlatformOverride: true,
    );
    addTearDown(controller.dispose);

    await controller.initialize();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(relayService.refreshPairingStatusCalls, 0);
    expect(relayService.credentialSyncCalls, 0);
    expect(relayService.secureMeshStatusCalls, 0);
    expect(controller.scannedTargets, isEmpty);
    expect(controller.selectedConversationAgentId, isEmpty);
    expect(controller.statusCaption, 'Ready');

    await controller.scanTargets();

    expect(relayService.refreshPairingStatusCalls, 1);
    expect(controller.scannedTargets, hasLength(1));
    expect(controller.scannedTargets.single.target, 'codex');
    expect(controller.scannedTargets.single.canRelayRuntime, isTrue);
    expect(controller.selectedConversationAgentId, 'codex');
    expect(controller.statusMessage, '已扫描 1 个目标适配器。');
  });

  test('mobile initialize exposes desktop authorized providers', () async {
    final directory = await Directory.systemTemp.createTemp(
      'lico-mobile-relay-providers-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final relayService = _FakeMobileRelayService()
      ..credentialSyncSucceeds = false
      ..config = MobileRelayConfig.defaults().copyWith(
        pairingId: 'pair-1',
        pcClientId: 'pc-1',
        pcClientName: 'ARC Desktop',
        mobileToken: 'mobile-token',
        mobileTokenPresent: true,
        paired: true,
        relayEnabled: false,
        authorizedProviders: const [
          MobileRelayAuthorizedProvider(
            providerId: 'chatgpt',
            label: 'ChatGPT',
            credentialPresent: true,
            source: 'desktop-model-profile',
          ),
        ],
      );
    final controller = FutureClientController(
      portableData: PortableDataRoot(dataDirectoryOverride: directory),
      agentService: _FakeAgentService(),
      mobileRelayService: relayService,
      mobileClientRuntimePlatformOverride: true,
    );
    addTearDown(controller.dispose);

    await controller.initialize();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(relayService.refreshPairingStatusCalls, 0);
    expect(relayService.credentialSyncCalls, 0);
    expect(relayService.secureMeshStatusCalls, 0);
    expect(controller.mobileAgentAccounts, hasLength(1));
    final account = controller.mobileAgentAccounts.single;
    expect(account.providerId, 'chatgpt');
    expect(account.credentialPresent, isTrue);
    expect(account.usesDesktopRelay, isTrue);
    expect(account.relayDeviceLabel, 'ARC Desktop');
  });

  test('mobile DeepSeek sends through paired computer provider chat', () async {
    final directory = await Directory.systemTemp.createTemp(
      'lico-mobile-deepseek-chat-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final relayService = _FakeMobileRelayService()
      ..config = MobileRelayConfig.defaults().copyWith(
        pairingId: 'pair-1',
        pcClientId: 'pc-1',
        pcClientName: 'ARC Desktop',
        mobileToken: 'mobile-token',
        mobileTokenPresent: true,
        paired: true,
        authorizedProviders: const [
          MobileRelayAuthorizedProvider(
            providerId: 'deepseek',
            label: 'DeepSeek',
            credentialPresent: true,
            source: 'desktop-model-profile',
          ),
        ],
      );
    final controller = FutureClientController(
      portableData: PortableDataRoot(dataDirectoryOverride: directory),
      agentService: _FakeAgentService(),
      mobileRelayService: relayService,
      mobileClientRuntimePlatformOverride: true,
    );
    addTearDown(controller.dispose);

    controller.mobileRelayConfig = relayService.config;
    controller.syncMobileAgentAccountsWithDesktopRelay();
    var account = controller.mobileAgentAccounts.single;

    await controller.updateMobileAgentGenerationOptions(
      account.id,
      selectedModel: 'deepseek-v4-pro',
      reasoningEffort: 'high',
    );
    account = controller.mobileAgentAccounts.single;

    await controller.sendMobileProviderMessage(
      account: account,
      text: '你好 DeepSeek',
    );

    expect(relayService.providerMessageCalls, 1);
    expect(relayService.lastProviderId, 'deepseek');
    expect(relayService.lastProviderText, '你好 DeepSeek');
    expect(relayService.lastProviderModel, 'deepseek-v4-pro');
    expect(relayService.lastProviderReasoningEffort, 'high');
    final session = controller.mobileProviderConversationFor(account);
    expect(session, isNotNull);
    expect(session!.messages.map((message) => message.role), [
      'user',
      'assistant',
    ]);
    expect(session.messages.first.text, '你好 DeepSeek');
    expect(session.messages.last.text, 'DeepSeek relay reply');
    expect(
      controller.mobileProviderConversationPreview(account),
      'DeepSeek relay reply',
    );
  });

  test(
    'mobile DeepSeek syncs credential after pairing and sends locally',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lico-mobile-deepseek-local-chat-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final relayService = _FakeMobileRelayService()
        ..config = MobileRelayConfig.defaults().copyWith(
          pairingId: 'pair-1',
          pcClientId: 'pc-1',
          pcClientName: 'ARC Desktop',
          mobileToken: 'mobile-token',
          mobileTokenPresent: true,
          paired: true,
          authorizedProviders: const [
            MobileRelayAuthorizedProvider(
              providerId: 'deepseek',
              label: 'DeepSeek',
              credentialPresent: true,
              source: 'desktop-model-profile',
            ),
          ],
        );
      final controller = FutureClientController(
        portableData: PortableDataRoot(dataDirectoryOverride: directory),
        agentService: _FakeAgentService(),
        mobileRelayService: relayService,
        mobileClientRuntimePlatformOverride: true,
      );
      addTearDown(controller.dispose);

      controller.mobileRelayConfig = relayService.config;
      controller.syncMobileAgentAccountsWithDesktopRelay();
      expect(
        controller.mobileAgentAccounts
            .singleWhere((account) => account.usesDesktopRelay)
            .usesDesktopRelay,
        isTrue,
      );

      await controller.syncMobileProviderCredentialsFromDesktopRelay();

      final account = controller.mobileAgentAccounts.singleWhere(
        (account) =>
            account.providerId == 'deepseek' &&
            account.authSource == MobileAgentAccount.authSourceMobileSynced,
      );
      expect(relayService.credentialSyncCalls, 1);
      expect(account.providerId, 'deepseek');
      expect(account.credentialPresent, isTrue);
      expect(account.usesDesktopRelay, isFalse);
      expect(account.credentialHint, '**** 4321');

      await controller.sendMobileProviderMessage(
        account: account,
        text: 'phone direct',
      );

      expect(relayService.localProviderMessageCalls, 1);
      expect(relayService.providerMessageCalls, 0);
      expect(relayService.lastLocalProviderId, 'deepseek');
      expect(relayService.lastLocalProviderText, 'phone direct');
      final session = controller.mobileProviderConversationFor(account);
      expect(session?.messages.last.text, 'DeepSeek phone reply');
    },
  );

  test(
    'mobile DeepSeek persists multiple local conversations with archive and trash',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lico-mobile-deepseek-persistent-chats-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final portableData = PortableDataRoot(dataDirectoryOverride: directory);
      final relayService = _FakeMobileRelayService();
      final controller = FutureClientController(
        portableData: portableData,
        agentService: _FakeAgentService(),
        mobileRelayService: relayService,
        mobileClientRuntimePlatformOverride: true,
      );
      addTearDown(controller.dispose);

      expect(
        mobileAgentProviderFor(
          'gemini',
        ).reasoningEffortOptions.map((option) => option.id),
        containsAll(['low', 'medium', 'high']),
      );
      expect(
        mobileAgentProviderFor(
          'kimi',
        ).reasoningEffortOptions.map((option) => option.id),
        containsAll(['enabled', 'disabled']),
      );
      await controller.addMobileAgentProvider('deepseek');
      await controller.configureMobileAgentApiKey(
        providerId: 'deepseek',
        apiKey: ['test-deepseek', '-api-key-4321'].join(),
      );
      final account = controller.mobileAgentAccounts.singleWhere(
        (account) => account.providerId == 'deepseek',
      );

      await controller.sendMobileProviderMessage(
        account: account,
        text: 'first persistent thread',
      );
      final first = controller.mobileProviderConversationFor(account);
      expect(first, isNotNull);

      await controller.startMobileProviderConversation(account);
      await controller.sendMobileProviderMessage(
        account: account,
        text: 'second persistent thread',
      );
      final second = controller.mobileProviderConversationFor(account);
      expect(second, isNotNull);
      expect(second!.id, isNot(first!.id));

      expect(
        controller.activeMobileProviderConversationsFor(account),
        hasLength(2),
      );
      expect(
        controller
            .activeMobileProviderConversationsFor(account)
            .map((record) => record.session.messages.first.text),
        containsAll(['first persistent thread', 'second persistent thread']),
      );

      final recordsFile = File(
        p.join(
          (await portableData.futureClientDirectory()).path,
          'mobile-provider-conversations.json',
        ),
      );
      final raw = await recordsFile.readAsString();
      expect(raw, contains('first persistent thread'));
      expect(raw, contains('second persistent thread'));
      expect(raw, isNot(contains('test-deepseek-api-key-4321')));

      await controller.archiveMobileProviderConversation(account, first.id);
      expect(
        controller.activeMobileProviderConversationsFor(account),
        hasLength(1),
      );
      expect(
        controller
            .archivedMobileProviderConversationsFor(account)
            .single
            .session
            .id,
        first.id,
      );

      await controller.trashMobileProviderConversation(account, second.id);
      expect(controller.activeMobileProviderConversationsFor(account), isEmpty);
      expect(
        controller
            .trashedMobileProviderConversationsFor(account)
            .single
            .session
            .id,
        second.id,
      );

      await controller.restoreMobileProviderConversation(account, second.id);
      expect(
        controller
            .activeMobileProviderConversationsFor(account)
            .single
            .session
            .id,
        second.id,
      );
      expect(
        controller.trashedMobileProviderConversationsFor(account),
        isEmpty,
      );

      final reloaded = FutureClientController(
        portableData: portableData,
        agentService: _FakeAgentService(),
        mobileRelayService: _FakeMobileRelayService(),
        mobileClientRuntimePlatformOverride: true,
      );
      addTearDown(reloaded.dispose);

      await reloaded.initialize();

      final reloadedAccount = reloaded.mobileAgentAccounts.singleWhere(
        (account) => account.providerId == 'deepseek',
      );
      expect(
        reloaded
            .activeMobileProviderConversationsFor(reloadedAccount)
            .single
            .session
            .id,
        second.id,
      );
      expect(
        reloaded
            .archivedMobileProviderConversationsFor(reloadedAccount)
            .single
            .session
            .id,
        first.id,
      );
      expect(
        reloaded
            .activeMobileProviderConversationsFor(reloadedAccount)
            .single
            .session
            .messages
            .map((message) => message.text),
        containsAll(['second persistent thread', 'DeepSeek phone reply']),
      );
    },
  );

  test('mobile provider trash is purged after thirty days', () async {
    final directory = await Directory.systemTemp.createTemp(
      'lico-mobile-provider-trash-purge-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final portableData = PortableDataRoot(dataDirectoryOverride: directory);
    const service = MobileProviderConversationService(
      store: PlatformMobileProviderConversationStore(),
    );
    final now = DateTime.utc(2026, 7, 4, 12);
    AgentConversationSession session(String id) {
      return AgentConversationSession(
        id: id,
        agentId: 'deepseek',
        title: id,
        createdAt: now.toIso8601String(),
        updatedAt: now.toIso8601String(),
        messages: const [],
      );
    }

    await service.save(portableData, [
      MobileProviderConversationRecord(
        accountId: 'deepseek-account',
        providerId: 'deepseek',
        status: mobileProviderConversationStatusActive,
        session: session('active'),
      ),
      MobileProviderConversationRecord(
        accountId: 'deepseek-account',
        providerId: 'deepseek',
        status: mobileProviderConversationStatusTrashed,
        deletedAt: now.subtract(const Duration(days: 31)).toIso8601String(),
        session: session('expired-trash'),
      ),
      MobileProviderConversationRecord(
        accountId: 'deepseek-account',
        providerId: 'deepseek',
        status: mobileProviderConversationStatusTrashed,
        deletedAt: now.subtract(const Duration(days: 2)).toIso8601String(),
        session: session('recent-trash'),
      ),
    ]);

    final loaded = await service.load(portableData, now: now);

    expect(loaded.map((record) => record.session.id), [
      'recent-trash',
      'active',
    ]);
  });

  test(
    'mobile falls back to default desktop credential profiles when provider echo is missing',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lico-mobile-deepseek-fallback-sync-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final relayService = _FakeMobileRelayService()
        ..config = MobileRelayConfig.defaults().copyWith(
          pairingId: 'pair-1',
          pcClientId: 'pc-1',
          pcClientName: 'ARC Desktop',
          mobileToken: 'mobile-token',
          mobileTokenPresent: true,
          paired: true,
          authorizedProviders: const [],
        );
      final controller = FutureClientController(
        portableData: PortableDataRoot(dataDirectoryOverride: directory),
        agentService: _FakeAgentService(),
        mobileRelayService: relayService,
        mobileClientRuntimePlatformOverride: true,
      );
      addTearDown(controller.dispose);

      controller.mobileRelayConfig = relayService.config;
      controller.syncMobileAgentAccountsWithDesktopRelay();
      expect(controller.mobileAgentAccounts, isEmpty);

      await controller.syncMobileProviderCredentialsFromDesktopRelay();

      expect(relayService.credentialSyncCalls, 1);
      expect(relayService.syncedProviderIds, ['deepseek']);
      expect(relayService.credentialSyncProfileIds, ['deepseek']);
      final account = controller.mobileAgentAccounts.singleWhere(
        (account) =>
            account.providerId == 'deepseek' &&
            account.authSource == MobileAgentAccount.authSourceMobileSynced,
      );
      expect(account.credentialPresent, isTrue);
      expect(account.usesDesktopRelay, isFalse);
      expect(account.relayProfileId, 'deepseek');
      final deepSeekAccounts = controller.mobileAgentAccounts
          .where((account) => account.providerId == 'deepseek')
          .toList(growable: false);
      expect(deepSeekAccounts, hasLength(1));
      expect(deepSeekAccounts.single.usesMobileSynced, isTrue);
      expect(
        controller.mobileAgentAccounts.any(
          (account) =>
              account.providerId == 'gemini' &&
              account.authSource == MobileAgentAccount.authSourceMobileSynced,
        ),
        isFalse,
      );
    },
  );

  test(
    'mobile ignores legacy desktop Gemini OAuth during phone sync',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lico-mobile-legacy-gemini-oauth-sync-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final relayService = _FakeMobileRelayService()
        ..credentialKindsByProvider['gemini'] = 'oauth-pkce'
        ..config = MobileRelayConfig.defaults().copyWith(
          pairingId: 'pair-1',
          pcClientId: 'pc-1',
          pcClientName: 'ARC Desktop',
          mobileToken: 'mobile-token',
          mobileTokenPresent: true,
          paired: true,
          relayEnabled: true,
          authorizedProviders: const [
            MobileRelayAuthorizedProvider(
              providerId: 'gemini',
              label: 'Legacy Gemini OAuth',
              credentialPresent: true,
              profileId: 'gemini-oauth',
              credentialKind: 'oauth-pkce',
              source: 'legacy-gemini-oauth',
            ),
          ],
        );
      final controller = FutureClientController(
        portableData: PortableDataRoot(dataDirectoryOverride: directory),
        agentService: _FakeAgentService(),
        mobileRelayService: relayService,
        mobileClientRuntimePlatformOverride: true,
      );
      addTearDown(controller.dispose);

      controller.mobileRelayConfig = relayService.config;
      controller.syncMobileAgentAccountsWithDesktopRelay();
      await controller.syncMobileProviderCredentialsFromDesktopRelay();

      expect(relayService.credentialSyncCalls, 0);
      expect(relayService.syncedProviderIds, isEmpty);
      expect(controller.mobileAgentAccounts, isEmpty);
    },
  );

  test('mobile refresh ignores legacy synced Gemini OAuth accounts', () async {
    final directory = await Directory.systemTemp.createTemp(
      'lico-mobile-legacy-gemini-oauth-refresh-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final relayService = _FakeMobileRelayService();
    final controller = FutureClientController(
      portableData: PortableDataRoot(dataDirectoryOverride: directory),
      agentService: _FakeAgentService(),
      mobileRelayService: relayService,
      mobileClientRuntimePlatformOverride: true,
    );
    addTearDown(controller.dispose);
    controller.mobileAgentAccounts = [
      MobileAgentAccount.create(
        mobileAgentProviderFor('gemini'),
        id: 'mobile-synced:gemini:gemini-oauth',
        label: 'Legacy Gemini OAuth',
        authSource: MobileAgentAccount.authSourceMobileSynced,
        credentialPresent: true,
        credentialHint: 'OAuth',
        relayProfileId: 'gemini-oauth',
      ),
    ];

    await controller.refreshMobileProviderOAuthCredentials();

    expect(relayService.oauthStatusCalls, 0);
    expect(relayService.oauthStatusProviderIds, isEmpty);
    final account = controller.mobileAgentAccounts.single;
    expect(account.providerId, 'gemini');
    expect(account.credentialPresent, isTrue);
    expect(account.credentialHint, 'OAuth');
  });

  test(
    'mobile DeepSeek fallback sync runs when paired flag lags behind current device echo',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lico-mobile-deepseek-lagging-paired-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final relayService = _FakeMobileRelayService()
        ..config = MobileRelayConfig.defaults().copyWith(
          pairingId: 'pair-1',
          pcClientId: 'pc-1',
          pcClientName: 'ARC Desktop',
          mobileToken: 'mobile-token',
          mobileTokenPresent: true,
          paired: false,
          authorizedProviders: const [],
        );
      final controller = FutureClientController(
        portableData: PortableDataRoot(dataDirectoryOverride: directory),
        agentService: _FakeAgentService(),
        mobileRelayService: relayService,
        mobileClientRuntimePlatformOverride: true,
      );
      addTearDown(controller.dispose);

      controller.mobileRelayConfig = relayService.config;
      await controller.syncMobileProviderCredentialsFromDesktopRelay();

      expect(relayService.credentialSyncCalls, 1);
      expect(relayService.syncedProviderIds, ['deepseek']);
      final account = controller.mobileAgentAccounts.singleWhere(
        (account) =>
            account.providerId == 'deepseek' &&
            account.authSource == MobileAgentAccount.authSourceMobileSynced,
      );
      expect(account.credentialPresent, isTrue);
      expect(
        controller.mobileAgentAccounts.any(
          (account) =>
              account.providerId == 'gemini' &&
              account.authSource == MobileAgentAccount.authSourceMobileSynced,
        ),
        isFalse,
      );
    },
  );

  test(
    'mobile credential sync resets stale pairing when relay no longer has it',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lico-mobile-stale-pairing-reset-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final relayService = _FakeMobileRelayService()
        ..credentialSyncPairingNotFound = true
        ..config = MobileRelayConfig.defaults().copyWith(
          pairingId: 'pair-stale',
          pcClientId: 'pc-1',
          pcClientName: 'ARC Desktop',
          mobileToken: 'mobile-token',
          mobileTokenPresent: true,
          paired: true,
          relayEnabled: true,
        );
      final controller = FutureClientController(
        portableData: PortableDataRoot(dataDirectoryOverride: directory),
        agentService: _FakeAgentService(),
        mobileRelayService: relayService,
        mobileClientRuntimePlatformOverride: true,
      );
      addTearDown(controller.dispose);

      controller.mobileRelayConfig = relayService.config;
      await controller.syncMobileProviderCredentialsFromDesktopRelay();

      expect(relayService.credentialSyncCalls, 1);
      expect(relayService.resetPairingCalls, 1);
      expect(controller.mobileRelayConfig.hasPairing, isFalse);
      expect(controller.mobileRelayConfig.paired, isFalse);
      expect(controller.mobileRelayConfig.relayEnabled, isFalse);
      expect(
        controller.mobileAgentAccounts.any(
          (account) => account.usesDesktopRelay,
        ),
        isFalse,
      );
    },
  );

  test('mobile direct API key providers send locally on phone', () async {
    final directory = await Directory.systemTemp.createTemp(
      'lico-mobile-local-providers-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final relayService = _FakeMobileRelayService();
    final controller = FutureClientController(
      portableData: PortableDataRoot(dataDirectoryOverride: directory),
      agentService: _FakeAgentService(),
      mobileRelayService: relayService,
      mobileClientRuntimePlatformOverride: true,
    );
    addTearDown(controller.dispose);

    final apiKeyProviders = mobileAgentProviders.where(
      (provider) => provider.authKind == MobileAgentAuthKind.apiKey,
    );
    for (final provider in apiKeyProviders) {
      await controller.addMobileAgentProvider(provider.id);
      await controller.configureMobileAgentApiKey(
        providerId: provider.id,
        apiKey: 'test-${provider.id}-api-key-4321',
      );
      final account = controller.mobileAgentAccounts.firstWhere(
        (account) => account.providerId == provider.id,
      );

      await controller.sendMobileProviderMessage(
        account: account,
        text: 'hello ${provider.id}',
      );

      expect(relayService.lastLocalProviderId, provider.id);
      expect(relayService.lastLocalProviderText, 'hello ${provider.id}');
      expect(relayService.lastLocalProviderModel, provider.defaultModel);
      expect(
        controller.mobileProviderConversationFor(account)?.messages.last.text,
        provider.id == 'deepseek'
            ? 'DeepSeek phone reply'
            : '${provider.id} phone reply',
      );
    }

    expect(relayService.saveProviderApiKeyCalls, apiKeyProviders.length);
    expect(relayService.localProviderMessageCalls, apiKeyProviders.length);
    expect(relayService.providerMessageCalls, 0);
  });

  test(
    'mobile provider generation options persist and drive local chat',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lico-mobile-generation-options-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final portableData = PortableDataRoot(dataDirectoryOverride: directory);
      final relayService = _FakeMobileRelayService();
      final controller = FutureClientController(
        portableData: portableData,
        agentService: _FakeAgentService(),
        mobileRelayService: relayService,
        mobileClientRuntimePlatformOverride: true,
      );
      addTearDown(controller.dispose);

      await controller.addMobileAgentProvider('deepseek');
      await controller.configureMobileAgentApiKey(
        providerId: 'deepseek',
        apiKey: ['test-deepseek', '-api-key-4321'].join(),
      );
      var account = controller.mobileAgentAccounts.singleWhere(
        (account) => account.providerId == 'deepseek',
      );

      await controller.updateMobileAgentGenerationOptions(
        account.id,
        selectedModel: 'deepseek-v4-pro',
        reasoningEffort: 'high',
      );

      account = controller.mobileAgentAccounts.singleWhere(
        (account) => account.providerId == 'deepseek',
      );
      expect(account.selectedModel, 'deepseek-v4-pro');
      expect(account.effectiveModel, 'deepseek-v4-pro');
      expect(account.reasoningEffort, 'high');

      final reloaded = FutureClientController(
        portableData: portableData,
        agentService: _FakeAgentService(),
        mobileRelayService: relayService,
        mobileClientRuntimePlatformOverride: true,
      );
      addTearDown(reloaded.dispose);
      await reloaded.initialize();
      account = reloaded.mobileAgentAccounts.singleWhere(
        (account) => account.providerId == 'deepseek',
      );

      await reloaded.sendMobileProviderMessage(
        account: account,
        text: 'hello deepseek',
      );

      expect(relayService.lastLocalProviderModel, 'deepseek-v4-pro');
      expect(relayService.lastLocalProviderReasoningEffort, 'high');
    },
  );

  test('mobile ChatGPT OAuth authorizes and sends locally on phone', () async {
    final directory = await Directory.systemTemp.createTemp(
      'lico-mobile-chatgpt-oauth-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final relayService = _FakeMobileRelayService();
    final controller = FutureClientController(
      portableData: PortableDataRoot(dataDirectoryOverride: directory),
      agentService: _FakeAgentService(),
      mobileRelayService: relayService,
      mobileClientRuntimePlatformOverride: true,
    );
    addTearDown(controller.dispose);

    await controller.addMobileAgentProvider('chatgpt');
    await controller.authorizeMobileAgentOAuth('chatgpt');

    final account = controller.mobileAgentAccounts.singleWhere(
      (account) => account.providerId == 'chatgpt',
    );
    expect(relayService.loginOAuthCalls, 1);
    expect(relayService.localProviderMessageCalls, 1);
    expect(relayService.lastLocalProviderText, contains('Lico Arc OAuth OK'));
    expect(relayService.lastLocalProviderModel, 'gpt-5.5');
    expect(account.credentialPresent, isTrue);
    expect(account.credentialHint, 'OAuth');
    expect(account.usesLocalOAuth, isTrue);

    await controller.sendMobileProviderMessage(
      account: account,
      text: 'hello oauth',
    );

    expect(relayService.localProviderMessageCalls, 2);
    expect(relayService.lastLocalProviderId, 'chatgpt');
    expect(relayService.lastLocalProviderText, 'hello oauth');
    expect(
      controller.mobileProviderConversationFor(account)?.messages.last.text,
      'chatgpt phone reply',
    );
    expect(controller.lastError, isEmpty);
  });

  test(
    'mobile ChatGPT OAuth configured account hides stale OAuth failure preview',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lico-mobile-chatgpt-oauth-stale-preview-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final relayService = _FakeMobileRelayService();
      final controller = FutureClientController(
        portableData: PortableDataRoot(dataDirectoryOverride: directory),
        agentService: _FakeAgentService(),
        mobileRelayService: relayService,
        mobileClientRuntimePlatformOverride: true,
      );
      addTearDown(controller.dispose);

      await controller.addMobileAgentProvider('chatgpt');
      await controller.authorizeMobileAgentOAuth('chatgpt');

      final account = controller.mobileAgentAccounts.singleWhere(
        (account) => account.providerId == 'chatgpt',
      );
      final now = DateTime.now().toUtc().toIso8601String();
      final session = AgentConversationSession(
        id: 'stale-chatgpt-session',
        agentId: 'chatgpt',
        title: 'hi',
        createdAt: now,
        updatedAt: now,
        adapterId: 'mobile-provider',
        sourceKind: 'mobile-provider',
        sourceClient: account.id,
        sourceClientLabel: account.label,
        native: false,
        readOnly: false,
        messageCount: 2,
        messages: [
          AgentConversationMessage(
            id: 'user-1',
            role: 'user',
            text: 'hi',
            createdAt: now,
          ),
          AgentConversationMessage(
            id: 'assistant-1',
            role: 'assistant',
            text: 'oauth_chat_failed (403, proxy: android-system-proxy)',
            createdAt: now,
          ),
        ],
      );
      controller.mobileProviderConversationRecordsByAccount = {
        account.id: [
          MobileProviderConversationRecord(
            accountId: account.id,
            providerId: account.providerId,
            status: mobileProviderConversationStatusActive,
            session: session,
          ),
        ],
      };
      controller.selectedMobileProviderConversationIds = {
        account.id: session.id,
      };

      expect(account.authState, MobileAgentAccount.authStateConfigured);
      expect(
        controller.mobileProviderConversationFor(account)?.preview,
        contains('403'),
      );
      expect(controller.mobileProviderConversationPreview(account), isEmpty);
    },
  );

  test(
    'mobile ChatGPT OAuth only succeeds after real chat validation',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lico-mobile-chatgpt-oauth-validation-failed-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final relayService = _FakeMobileRelayService()
        ..localProviderStatusCodesByProvider['chatgpt'] = 403;
      final controller = FutureClientController(
        portableData: PortableDataRoot(dataDirectoryOverride: directory),
        agentService: _FakeAgentService(),
        mobileRelayService: relayService,
        mobileClientRuntimePlatformOverride: true,
      );
      addTearDown(controller.dispose);

      await controller.addMobileAgentProvider('chatgpt');
      await controller.authorizeMobileAgentOAuth('chatgpt');

      final account = controller.mobileAgentAccounts.singleWhere(
        (account) => account.providerId == 'chatgpt',
      );
      final prompt = controller.mobileAgentOAuthAuthorizationPromptFor(account);
      expect(relayService.loginOAuthCalls, 1);
      expect(relayService.localProviderMessageCalls, 1);
      expect(account.credentialPresent, isTrue);
      expect(
        account.authState,
        MobileAgentAccount.authStateChatValidationFailed,
      );
      expect(prompt?.isFailed, isTrue);
      expect(controller.lastError, contains('403'));
      expect(controller.statusMessage, contains('真实对话验证失败'));
    },
  );

  test('mobile ChatGPT OAuth ignores stale status without timestamp', () async {
    final directory = await Directory.systemTemp.createTemp(
      'lico-mobile-chatgpt-oauth-stale-status-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final loginCompleter = Completer<Map<String, dynamic>>();
    final relayService = _FakeMobileRelayService()
      ..loginOAuthCompleter = loginCompleter
      ..oauthStatusCredentialPresent = true
      ..oauthStatusIncludeUpdatedAt = false;
    final controller = FutureClientController(
      portableData: PortableDataRoot(dataDirectoryOverride: directory),
      agentService: _FakeAgentService(),
      mobileRelayService: relayService,
      mobileClientRuntimePlatformOverride: true,
    );
    addTearDown(controller.dispose);

    await controller.addMobileAgentProvider('chatgpt');
    final authFuture = controller.authorizeMobileAgentOAuth('chatgpt');
    for (var attempt = 0; attempt < 20; attempt++) {
      if (relayService.loginOAuthCalls >= 1) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await controller.refreshPendingMobileAgentOAuthAuthorizations();

    var account = controller.mobileAgentAccounts.singleWhere(
      (account) => account.providerId == 'chatgpt',
    );
    expect(account.credentialPresent, isFalse);
    expect(
      controller.mobileAgentOAuthAuthorizationPromptFor(account)?.isWaiting,
      isTrue,
    );
    expect(relayService.localProviderMessageCalls, 0);

    loginCompleter.complete({
      'ok': true,
      'providerId': 'chatgpt',
      'mobileAccountId': account.id,
      'credentialPresent': true,
      'credentialKind': 'oauth-pkce',
      'credentialHint': 'OAuth',
    });
    await authFuture;

    account = controller.mobileAgentAccounts.singleWhere(
      (account) => account.providerId == 'chatgpt',
    );
    expect(account.credentialPresent, isTrue);
    expect(relayService.localProviderMessageCalls, 1);
  });

  test(
    'mobile ChatGPT OAuth poll success is not shown again when login returns',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lico-mobile-chatgpt-oauth-consumed-success-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final loginCompleter = Completer<Map<String, dynamic>>();
      final relayService = _FakeMobileRelayService()
        ..loginOAuthCompleter = loginCompleter
        ..oauthStatusCredentialPresent = false;
      final controller = FutureClientController(
        portableData: PortableDataRoot(dataDirectoryOverride: directory),
        agentService: _FakeAgentService(),
        mobileRelayService: relayService,
        mobileClientRuntimePlatformOverride: true,
      );
      addTearDown(controller.dispose);

      await controller.addMobileAgentProvider('chatgpt');
      final authFuture = controller.authorizeMobileAgentOAuth('chatgpt');
      for (var attempt = 0; attempt < 20; attempt++) {
        if (relayService.loginOAuthCalls >= 1) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      var account = controller.mobileAgentAccounts.singleWhere(
        (account) => account.providerId == 'chatgpt',
      );
      expect(
        controller.mobileAgentOAuthAuthorizationPromptFor(account)?.isWaiting,
        isTrue,
      );

      relayService.oauthStatusCredentialPresent = true;
      await controller.refreshPendingMobileAgentOAuthAuthorizations();
      account = controller.mobileAgentAccounts.singleWhere(
        (account) => account.providerId == 'chatgpt',
      );
      expect(account.credentialPresent, isTrue);
      expect(relayService.localProviderMessageCalls, 1);
      expect(
        controller.mobileAgentOAuthAuthorizationPromptFor(account)?.isSuccess,
        isTrue,
      );

      controller.dismissMobileAgentOAuthAuthorizationPrompt(account);
      expect(
        controller.mobileAgentOAuthAuthorizationPromptFor(account)?.isDismissed,
        isTrue,
      );

      loginCompleter.complete({
        'ok': true,
        'providerId': 'chatgpt',
        'mobileAccountId': account.id,
        'credentialPresent': true,
        'credentialKind': 'oauth-pkce',
        'credentialHint': 'OAuth',
      });
      await authFuture;

      account = controller.mobileAgentAccounts.singleWhere(
        (account) => account.providerId == 'chatgpt',
      );
      expect(relayService.localProviderMessageCalls, 1);
      expect(
        controller.mobileAgentOAuthAuthorizationPromptFor(account)?.isDismissed,
        isTrue,
      );
    },
  );

  test('mobile Gemini OAuth is unsupported on phone', () async {
    final directory = await Directory.systemTemp.createTemp(
      'lico-mobile-gemini-local-oauth-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final relayService = _FakeMobileRelayService();
    final controller = FutureClientController(
      portableData: PortableDataRoot(dataDirectoryOverride: directory),
      agentService: _FakeAgentService(),
      mobileRelayService: relayService,
      mobileClientRuntimePlatformOverride: true,
    );
    addTearDown(controller.dispose);

    await controller.authorizeMobileAgentOAuth(
      'gemini',
      mobileAccountId: 'gemini-oauth',
    );

    expect(relayService.loginOAuthCalls, 0);
    expect(controller.lastError, contains('不支持手机端本地网页授权'));
    expect(controller.mobileAgentAccounts, isEmpty);
  });

  test(
    'mobile OAuth chat failure keeps credential and shows HTTP status code',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lico-mobile-chatgpt-oauth-failed-status-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final relayService = _FakeMobileRelayService()
        ..localProviderStatusCodeQueuesByProvider['chatgpt'] = [0, 403];
      final controller = FutureClientController(
        portableData: PortableDataRoot(dataDirectoryOverride: directory),
        agentService: _FakeAgentService(),
        mobileRelayService: relayService,
        mobileClientRuntimePlatformOverride: true,
      );
      addTearDown(controller.dispose);

      await controller.addMobileAgentProvider('chatgpt');
      await controller.authorizeMobileAgentOAuth('chatgpt');
      final account = controller.mobileAgentAccounts.singleWhere(
        (account) => account.providerId == 'chatgpt',
      );

      await controller.sendMobileProviderMessage(
        account: account,
        text: 'hello oauth',
      );

      expect(controller.lastError, 'oauth_chat_failed (403, proxy: direct)');
      final updatedAccount = controller.mobileAgentAccounts.singleWhere(
        (next) => next.id == account.id,
      );
      expect(updatedAccount.credentialPresent, isTrue);
      expect(
        updatedAccount.authState,
        MobileAgentAccount.authStateChatValidationFailed,
      );
      expect(
        controller.mobileAgentOAuthAuthorizationPromptFor(account)?.isFailed,
        isTrue,
      );
      final messages =
          controller.mobileProviderConversationFor(account)?.messages ??
          const [];
      expect(messages.map((message) => message.role), ['user']);
      expect(messages.last.text, 'hello oauth');
    },
  );

  test(
    'mobile ChatGPT OAuth missing credential shows recovery prompt',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lico-mobile-chatgpt-oauth-missing-credential-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final relayService = _FakeMobileRelayService();
      final controller = FutureClientController(
        portableData: PortableDataRoot(dataDirectoryOverride: directory),
        agentService: _FakeAgentService(),
        mobileRelayService: relayService,
        mobileClientRuntimePlatformOverride: true,
      );
      addTearDown(controller.dispose);

      await controller.addMobileAgentProvider('chatgpt');
      await controller.authorizeMobileAgentOAuth('chatgpt');
      relayService.localProviderFailuresByProvider['chatgpt'] = {
        'status': 'oauth_credential_missing',
        'message': 'ChatGPT OAuth authorization is missing on this phone.',
      };
      final account = controller.mobileAgentAccounts.singleWhere(
        (account) => account.providerId == 'chatgpt',
      );

      await controller.sendMobileProviderMessage(
        account: account,
        text: 'hello missing oauth',
      );

      final updatedAccount = controller.mobileAgentAccounts.singleWhere(
        (next) => next.id == account.id,
      );
      expect(updatedAccount.credentialPresent, isFalse);
      expect(controller.lastError, contains('oauth_credential_missing'));
      expect(
        controller.mobileAgentOAuthAuthorizationPromptFor(account)?.isFailed,
        isTrue,
      );
      final messages =
          controller.mobileProviderConversationFor(account)?.messages ??
          const [];
      expect(messages.map((message) => message.role), ['user']);
      expect(messages.last.text, 'hello missing oauth');
    },
  );

  test(
    'mobile ChatGPT OAuth status refresh clears missing credential',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lico-mobile-chatgpt-oauth-status-missing-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final relayService = _FakeMobileRelayService();
      final controller = FutureClientController(
        portableData: PortableDataRoot(dataDirectoryOverride: directory),
        agentService: _FakeAgentService(),
        mobileRelayService: relayService,
        mobileClientRuntimePlatformOverride: true,
      );
      addTearDown(controller.dispose);

      await controller.addMobileAgentProvider('chatgpt');
      await controller.authorizeMobileAgentOAuth('chatgpt');
      final account = controller.mobileAgentAccounts.singleWhere(
        (account) => account.providerId == 'chatgpt',
      );
      expect(account.credentialPresent, isTrue);

      relayService.oauthStatusCredentialPresent = false;
      await controller.refreshMobileProviderOAuthCredentials();

      final updatedAccount = controller.mobileAgentAccounts.singleWhere(
        (next) => next.id == account.id,
      );
      expect(updatedAccount.credentialPresent, isFalse);
      expect(
        controller
            .mobileAgentOAuthAuthorizationPromptFor(updatedAccount)
            ?.isFailed,
        isTrue,
      );
      expect(controller.statusMessage, contains('OAuth 需要重新授权'));
    },
  );

  test(
    'mobile ChatGPT OAuth startup defers native credential revalidation',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lico-mobile-chatgpt-oauth-startup-refresh-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final portableData = PortableDataRoot(dataDirectoryOverride: directory);
      await const MobileAgentAccountService(
        store: PlatformMobileAgentAccountStore(),
      ).markOAuthConversationValidationFailed(
        portableData,
        'chatgpt',
        accountId: 'chatgpt',
        credentialHint: 'OAuth',
      );
      final relayService = _FakeMobileRelayService()
        ..oauthStatusCredentialPresent = true;
      final controller = FutureClientController(
        portableData: portableData,
        agentService: _FakeAgentService(),
        mobileRelayService: relayService,
        mobileClientRuntimePlatformOverride: true,
      );
      addTearDown(controller.dispose);

      await controller.initialize();

      final account = controller.mobileAgentAccounts.singleWhere(
        (account) => account.providerId == 'chatgpt',
      );
      expect(relayService.oauthStatusCalls, 0);
      expect(relayService.localProviderMessageCalls, 0);
      expect(account.credentialPresent, isTrue);
      expect(
        account.authState,
        MobileAgentAccount.authStateChatValidationFailed,
      );

      await controller.refreshMobileProviderOAuthCredentials();

      final refreshed = controller.mobileAgentAccounts.singleWhere(
        (account) => account.providerId == 'chatgpt',
      );
      expect(relayService.oauthStatusCalls, 1);
      expect(relayService.localProviderMessageCalls, 1);
      expect(refreshed.credentialPresent, isTrue);
      expect(refreshed.authState, MobileAgentAccount.authStateConfigured);
      expect(
        controller.mobileAgentOAuthAuthorizationPromptFor(refreshed),
        isNull,
      );
    },
  );

  test('mobile ChatGPT OAuth Android bridge uses ChatGPT Codex responses', () {
    final bridge = File(
      p.join(
        Directory.current.path,
        'android',
        'app',
        'src',
        'main',
        'kotlin',
        'com',
        'liko',
        'arc',
        'MainActivity.kt',
      ),
    ).readAsStringSync();

    expect(bridge, contains('https://chatgpt.com/backend-api/codex/responses'));
    expect(
      bridge,
      contains(
        'https://chatgpt.com/backend-api/codex/models?client_version=1.0.0',
      ),
    );
    expect(bridge, contains('chatgpt-oauth-codex-responses'));
    expect(bridge, isNot(contains('OpenAI-Beta')));
    expect(bridge, isNot(contains('responses=experimental')));
    expect(bridge, isNot(contains('chatgpt-account-id')));
    expect(bridge, contains('ChatGPT-Account-ID'));
    expect(bridge, contains('jwtOpenAICodexAccountId'));
    expect(
      bridge,
      contains('private const val CHATGPT_OAUTH_DEFAULT_MODEL = "gpt-5.5"'),
    );
    expect(
      bridge,
      isNot(
        contains('private const val CHATGPT_OAUTH_DEFAULT_MODEL = "gpt-5.4"'),
      ),
    );
    expect(bridge, contains('selectChatGptCodexResponsesModel'));
    expect(bridge, contains('chatGptCodexResponsesErrorSummary'));
    expect(bridge, contains('normalizeChatGptReasoningEffort'));
    expect(bridge, contains('params.optString("reasoningEffort", "")'));
    expect(
      bridge,
      contains(
        'request.put("reasoning", JSONObject().put("effort", reasoningEffort))',
      ),
    );
    expect(bridge, contains('"response.output_item.done"'));
    expect(bridge, contains('"response.text.delta"'));
    expect(bridge, contains('"response.refusal.delta"'));
    expect(bridge, contains('Follow the user request.'));
    expect(bridge, contains('oauth_account_id_missing'));
    expect(bridge, contains('oauth_credential_missing'));
    expect(bridge, contains('mobileProviderChatCanRunWithoutNativeRuntime'));
    expect(bridge, contains('"response.failed"'));
    expect(bridge, contains('"error" ->'));
    expect(
      bridge,
      contains('The app will verify direct ChatGPT chat before marking'),
    );
    expect(bridge, isNot(contains('authorization complete')));
    final loginBridge = RegExp(
      r'private fun loginMobileProviderOAuth[\s\S]*?private fun completeMobileProviderOAuthCallback',
    ).firstMatch(bridge)?.group(0);
    expect(loginBridge, isNotNull);
    expect(
      loginBridge,
      contains('!isSupportedLocalMobileProviderOAuth(providerId)'),
    );
    final callbackBridge = RegExp(
      r'private fun completeMobileProviderOAuthCallback[\s\S]*?private fun mobileProviderOAuthStatus',
    ).firstMatch(bridge)?.group(0);
    expect(callbackBridge, isNotNull);
    expect(
      callbackBridge,
      contains('!isSupportedLocalMobileProviderOAuth(providerId)'),
    );
    expect(bridge, contains('MobileProviderOAuthDefinition('));
    expect(bridge, contains('authSurface = "openai-chatgpt-oauth"'));
    expect(bridge, contains('conversationSurface = "chatgpt-codex-responses"'));
    expect(bridge, isNot(contains('google-oauth-gemini-api')));
    expect(bridge, isNot(contains('gemini-api-generate-content')));
    expect(bridge, isNot(contains('private fun geminiAuthorizeUrl(')));
    expect(bridge, isNot(contains('GEMINI_OAUTH_AUTHORIZE_URL')));
    expect(bridge, isNot(contains('GEMINI_OAUTH_TOKEN_URL')));
    expect(bridge, isNot(contains('GEMINI_OAUTH_CALLBACK_PORT')));
    expect(bridge, isNot(contains('GEMINI_OAUTH_CALLBACK_PATH')));
    expect(bridge, contains('mobileProviderOAuthCallbackPort(providerId)'));
    expect(bridge, isNot(contains('exchangeGeminiOAuthCode(')));
    expect(bridge, isNot(contains('refreshGeminiOAuthCredentialIfNeeded(')));
    final statusBridge = RegExp(
      r'private fun mobileProviderOAuthStatus[\s\S]*?private fun waitForMobileProviderOAuthCredential',
    ).firstMatch(bridge)?.group(0);
    expect(statusBridge, isNotNull);
    expect(
      statusBridge,
      contains('!isSupportedLocalMobileProviderOAuth(providerId)'),
    );
    expect(statusBridge, contains('updatedAtEpochMillis'));
    expect(bridge, contains('minUpdatedAtEpochMillis = oauthStartedAt'));
    expect(
      bridge,
      isNot(contains('https://chatgpt.com/backend-api/conversation')),
    );
    expect(bridge, isNot(contains('chatgpt-oauth-web-conversation')));
  });

  test('Android client locks app portrait without changing system rotation', () {
    const androidNamespace = 'http://schemas.android.com/apk/res/android';
    final projectRoot = Directory.current.path;
    final manifestPath = p.join(
      projectRoot,
      'android',
      'app',
      'src',
      'main',
      'AndroidManifest.xml',
    );
    final manifest = File(manifestPath).readAsStringSync();
    final document = XmlDocument.parse(manifest);
    final activities = document.findAllElements('activity').toList();

    expect(
      activities.map(
        (activity) =>
            activity.getAttribute('name', namespaceUri: androidNamespace),
      ),
      containsAll(['.MainActivity', '.ChatGptWebActivity']),
    );
    for (final activity in activities) {
      expect(
        activity.getAttribute(
          'screenOrientation',
          namespaceUri: androidNamespace,
        ),
        'portrait',
        reason:
            '${activity.getAttribute('name', namespaceUri: androidNamespace)} '
            'must stay app-local portrait without changing system rotation.',
      );
    }

    final sourceText = [
      manifest,
      ..._readSourceFiles(p.join(projectRoot, 'android', 'app', 'src')),
      ..._readSourceFiles(p.join(projectRoot, 'lib')),
    ].join('\n');

    for (final forbidden in [
      'android.permission.WRITE_SETTINGS',
      'Settings.System',
      'accelerometer_rotation',
      'user_rotation',
      'setRequestedOrientation',
      'SystemChrome.setPreferredOrientations',
      'DeviceOrientation',
    ]) {
      expect(sourceText, isNot(contains(forbidden)));
    }
  });

  test('mobile OAuth provider HTTPS uses detected Android proxy', () {
    final bridge = File(
      p.join(
        Directory.current.path,
        'android',
        'app',
        'src',
        'main',
        'kotlin',
        'com',
        'liko',
        'arc',
        'MainActivity.kt',
      ),
    ).readAsStringSync();

    expect(bridge, contains('private fun currentAndroidHttpProxy()'));
    expect(bridge, contains('android.net.Proxy.getHost(this)'));
    expect(bridge, contains('System.getProperty("https.proxyHost")'));
    expect(bridge, contains('System.getProperty("http.proxyHost")'));
    expect(bridge, contains('private fun currentProxySelectorProxy('));
    expect(bridge, contains('java.net.ProxySelector.getDefault()'));
    expect(bridge, contains('url.openConnection(androidProxy.toJavaProxy())'));
    expect(bridge, contains('url.openConnection(selectorProxy)'));
    expect(bridge, contains('"android-system-proxy"'));
    expect(bridge, contains('"java-proxy-selector"'));
    expect(bridge, isNot(contains('Proxy.NO_PROXY')));

    final tokenExchangeBridge = RegExp(
      r'private fun exchangeChatGptOAuthCode[\s\S]*?private fun writeMobileProviderOAuthCredential',
    ).firstMatch(bridge)?.group(0);
    expect(tokenExchangeBridge, isNotNull);
    expect(
      tokenExchangeBridge,
      contains('openProviderHttpsConnection(definition.tokenUrl)'),
    );

    final refreshBridge = RegExp(
      r'private fun refreshChatGptOAuthCredentialIfNeeded[\s\S]*?private fun secureMeshNativeLibraryUnavailable',
    ).firstMatch(bridge)?.group(0);
    expect(refreshBridge, isNotNull);
    expect(
      refreshBridge,
      contains('openProviderHttpsConnection(definition.tokenUrl)'),
    );

    expect(bridge, isNot(contains('private fun sendGeminiOAuthMessage')));
    expect(bridge, isNot(contains('GEMINI_OAUTH_GENERATE_CONTENT_BASE_URL')));

    final chatGptBridge = RegExp(
      r'private fun sendChatGptCodexResponsesMessage[\s\S]*?private fun chatGptCodexResponsesRequest',
    ).firstMatch(bridge)?.group(0);
    expect(chatGptBridge, isNotNull);
    expect(
      chatGptBridge,
      contains('openProviderHttpsConnection(CHATGPT_CODEX_RESPONSES_URL)'),
    );
  });

  test('mobile ChatGPT OAuth supports multiple local accounts', () async {
    final directory = await Directory.systemTemp.createTemp(
      'lico-mobile-chatgpt-oauth-multi-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final relayService = _FakeMobileRelayService();
    final controller = FutureClientController(
      portableData: PortableDataRoot(dataDirectoryOverride: directory),
      agentService: _FakeAgentService(),
      mobileRelayService: relayService,
      mobileClientRuntimePlatformOverride: true,
    );
    addTearDown(controller.dispose);

    await controller.addMobileAgentProvider('chatgpt');
    final firstDraft = controller.mobileAgentAccounts.single;
    await controller.authorizeMobileAgentOAuth(
      'chatgpt',
      mobileAccountId: firstDraft.id,
    );
    await controller.addMobileAgentProvider('chatgpt');
    final secondDraft = controller.mobileAgentAccounts.singleWhere(
      (account) =>
          account.providerId == 'chatgpt' && !account.credentialPresent,
    );
    await controller.authorizeMobileAgentOAuth(
      'chatgpt',
      mobileAccountId: secondDraft.id,
    );

    final chatGptAccounts = controller.mobileAgentAccounts
        .where((account) => account.providerId == 'chatgpt')
        .toList(growable: false);
    expect(chatGptAccounts, hasLength(2));
    expect(chatGptAccounts.map((account) => account.id).toSet(), hasLength(2));
    expect(chatGptAccounts.every((account) => account.usesLocalOAuth), isTrue);
    expect(relayService.loginOAuthCalls, 2);
    expect(relayService.localProviderMessageCalls, 2);
    expect(
      relayService.loginOAuthMobileAccountIds.toSet(),
      chatGptAccounts.map((account) => account.id).toSet(),
    );

    await controller.sendMobileProviderMessage(
      account: chatGptAccounts.first,
      text: 'hello first oauth',
    );
    await controller.sendMobileProviderMessage(
      account: chatGptAccounts.last,
      text: 'hello second oauth',
    );

    expect(relayService.localProviderMessageCalls, 4);
    expect(relayService.localMessageMobileAccountIds, [
      chatGptAccounts.first.id,
      chatGptAccounts.last.id,
      chatGptAccounts.first.id,
      chatGptAccounts.last.id,
    ]);
    expect(relayService.localProviderTexts.sublist(2), [
      'hello first oauth',
      'hello second oauth',
    ]);
    expect(controller.mobileProviderConversations.keys.toSet(), {
      chatGptAccounts.first.id,
      chatGptAccounts.last.id,
    });
  });

  test(
    'mobile provider direct conversation can hand off context to desktop agent',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lico-mobile-chatgpt-handoff-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final relayService = _FakeMobileRelayService();
      final controller = FutureClientController(
        portableData: PortableDataRoot(dataDirectoryOverride: directory),
        agentService: _FakeAgentService(),
        mobileRelayService: relayService,
        mobileClientRuntimePlatformOverride: true,
      );
      addTearDown(controller.dispose);
      controller.mobileRelayConfig = MobileRelayConfig.defaults().copyWith(
        pairingId: 'pair-1',
        pcClientId: 'pc-1',
        pcClientName: 'ARC Desktop',
        mobileTokenPresent: true,
        paired: true,
        relayEnabled: true,
      );
      controller.scannedTargets = [
        TargetCandidate(
          target: 'codex',
          label: 'Codex',
          kind: 'cli',
          status: 'detected',
          configured: true,
          confidence: 0.9,
          adapterStatus: 'implemented',
          adapterCapabilities: _parityReadyAdapterCapabilities,
          supportedActions: const ['runtime.message.send'],
        ),
      ];

      await controller.addMobileAgentProvider('deepseek');
      final draft = controller.mobileAgentAccounts.singleWhere(
        (account) => account.providerId == 'deepseek',
      );
      await controller.configureMobileAgentApiKey(
        providerId: 'deepseek',
        mobileAccountId: draft.id,
        apiKey: ['deepseek-te', 'st-key-1111'].join(),
      );
      final account = controller.mobileAgentAccounts.singleWhere(
        (account) => account.providerId == 'deepseek',
      );
      await controller.sendMobileProviderMessage(
        account: account,
        text: 'summarize the deployment plan',
      );
      await controller.handoffMobileProviderConversationToAgent(
        account: account,
        targetAgentId: 'codex',
        prompt: 'Create a task list.',
      );

      expect(relayService.localProviderMessageCalls, 1);
      expect(relayService.secureAgentMessageCalls, 1);
      expect(relayService.lastAgentId, 'codex');
      expect(relayService.lastAgentText, contains('DeepSeek 手机端直连对话上下文'));
      expect(
        relayService.lastAgentText,
        contains('[user]\nsummarize the deployment plan'),
      );
      expect(
        relayService.lastAgentText,
        contains('[assistant]\nDeepSeek phone reply'),
      );
      expect(relayService.lastAgentText, contains('Create a task list.'));
      expect(controller.selectedConversationAgentId, 'codex');
      expect(
        controller
            .conversationSessionsByAgent['codex']
            ?.single
            .messages
            .last
            .text,
        'Codex relay reply',
      );
      expect(controller.lastError, isEmpty);
    },
  );

  test('mobile ChatGPT handoff requires a web conversation snapshot', () async {
    final directory = await Directory.systemTemp.createTemp(
      'lico-mobile-chatgpt-web-handoff-required-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final relayService = _FakeMobileRelayService()
      ..webSnapshotResult = {
        'ok': true,
        'snapshotPresent': false,
        'messages': const [],
      };
    final controller = FutureClientController(
      portableData: PortableDataRoot(dataDirectoryOverride: directory),
      agentService: _FakeAgentService(),
      mobileRelayService: relayService,
      mobileClientRuntimePlatformOverride: true,
    );
    addTearDown(controller.dispose);
    controller.scannedTargets = [
      TargetCandidate(
        target: 'codex',
        label: 'Codex',
        kind: 'cli',
        status: 'detected',
        configured: true,
        confidence: 0.9,
        adapterStatus: 'implemented',
        adapterCapabilities: _parityReadyAdapterCapabilities,
        supportedActions: const ['runtime.message.send'],
      ),
    ];

    await controller.addMobileAgentProvider('chatgpt');
    await controller.authorizeMobileAgentOAuth('chatgpt');
    final account = controller.mobileAgentAccounts.singleWhere(
      (account) => account.providerId == 'chatgpt',
    );
    await controller.sendMobileProviderMessage(
      account: account,
      text: 'local provider fallback question',
    );
    await controller.handoffMobileProviderConversationToAgent(
      account: account,
      targetAgentId: 'codex',
      prompt: 'Do not send without web context.',
    );

    expect(relayService.webSnapshotCalls, 1);
    expect(relayService.secureAgentMessageCalls, 0);
    expect(relayService.lastAgentText, isEmpty);
    expect(controller.lastError, contains('ChatGPT 网页端对话暂无可转交内容'));
  });

  test('mobile ChatGPT handoff prefers web conversation snapshot', () async {
    final directory = await Directory.systemTemp.createTemp(
      'lico-mobile-chatgpt-web-handoff-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final relayService = _FakeMobileRelayService()
      ..webSnapshotResult = {
        'ok': true,
        'snapshotPresent': true,
        'capturedAt': '2026-07-03T20:30:00Z',
        'messages': [
          {
            'index': 0,
            'role': 'user',
            'text': 'web page question about deployment',
          },
          {
            'index': 1,
            'role': 'assistant',
            'text': 'web page answer from ChatGPT',
          },
        ],
      };
    final controller = FutureClientController(
      portableData: PortableDataRoot(dataDirectoryOverride: directory),
      agentService: _FakeAgentService(),
      mobileRelayService: relayService,
      mobileClientRuntimePlatformOverride: true,
    );
    addTearDown(controller.dispose);
    controller.scannedTargets = [
      TargetCandidate(
        target: 'codex',
        label: 'Codex',
        kind: 'cli',
        status: 'detected',
        configured: true,
        confidence: 0.9,
        adapterStatus: 'implemented',
        adapterCapabilities: _parityReadyAdapterCapabilities,
        supportedActions: const ['runtime.message.send'],
      ),
    ];

    await controller.addMobileAgentProvider('chatgpt');
    await controller.authorizeMobileAgentOAuth('chatgpt');
    final account = controller.mobileAgentAccounts.singleWhere(
      (account) => account.providerId == 'chatgpt',
    );
    await controller.sendMobileProviderMessage(
      account: account,
      text: 'local provider fallback question',
    );
    await controller.handoffMobileProviderConversationToAgent(
      account: account,
      targetAgentId: 'codex',
      prompt: 'Use the web snapshot.',
    );

    expect(relayService.webSnapshotCalls, 1);
    expect(relayService.lastAgentText, contains('web page question'));
    expect(relayService.lastAgentText, contains('web page answer'));
    expect(
      relayService.lastAgentText,
      isNot(contains('local provider fallback question')),
    );
    expect(relayService.lastAgentText, contains('Use the web snapshot.'));
  });

  test('mobile DeepSeek supports multiple local API key accounts', () async {
    final directory = await Directory.systemTemp.createTemp(
      'lico-mobile-deepseek-local-multi-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final relayService = _FakeMobileRelayService();
    final controller = FutureClientController(
      portableData: PortableDataRoot(dataDirectoryOverride: directory),
      agentService: _FakeAgentService(),
      mobileRelayService: relayService,
      mobileClientRuntimePlatformOverride: true,
    );
    addTearDown(controller.dispose);

    await controller.addMobileAgentProvider('deepseek');
    final firstDraft = controller.mobileAgentAccounts.single;
    await controller.configureMobileAgentApiKey(
      providerId: 'deepseek',
      mobileAccountId: firstDraft.id,
      apiKey: ['deepseek-fi', 'rst-key-1111'].join(),
    );
    await controller.addMobileAgentProvider('deepseek');
    final secondDraft = controller.mobileAgentAccounts.singleWhere(
      (account) =>
          account.providerId == 'deepseek' && !account.credentialPresent,
    );
    await controller.configureMobileAgentApiKey(
      providerId: 'deepseek',
      mobileAccountId: secondDraft.id,
      apiKey: ['deepseek-sec', 'ond-key-2222'].join(),
    );

    final deepSeekAccounts = controller.mobileAgentAccounts
        .where((account) => account.providerId == 'deepseek')
        .toList(growable: false);
    expect(deepSeekAccounts, hasLength(2));
    expect(deepSeekAccounts.map((account) => account.id).toSet(), hasLength(2));
    expect(deepSeekAccounts.map((account) => account.credentialHint), [
      '**** 1111',
      '**** 2222',
    ]);
    expect(relayService.saveProviderApiKeyCalls, 2);
    expect(relayService.savedMobileAccountIds, [
      deepSeekAccounts.first.id,
      deepSeekAccounts.last.id,
    ]);

    await controller.sendMobileProviderMessage(
      account: deepSeekAccounts.first,
      text: 'first phone direct',
    );
    await controller.sendMobileProviderMessage(
      account: deepSeekAccounts.last,
      text: 'second phone direct',
    );

    expect(relayService.localProviderMessageCalls, 2);
    expect(relayService.localMessageMobileAccountIds, [
      deepSeekAccounts.first.id,
      deepSeekAccounts.last.id,
    ]);
    expect(controller.mobileProviderConversations.keys.toSet(), {
      deepSeekAccounts.first.id,
      deepSeekAccounts.last.id,
    });
  });

  test('mobile account load drops default blank draft after sync', () async {
    final directory = await Directory.systemTemp.createTemp(
      'lico-mobile-account-clean-default-draft-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final portableData = PortableDataRoot(dataDirectoryOverride: directory);
    const service = MobileAgentAccountService(
      store: PlatformMobileAgentAccountStore(),
    );
    final provider = mobileAgentProviderFor('deepseek');
    final synced = MobileAgentAccount.create(
      provider,
      id: 'synced:deepseek',
      authSource: MobileAgentAccount.authSourceMobileSynced,
      credentialPresent: true,
      relayProfileId: 'deepseek',
    );
    final secondConfigured = MobileAgentAccount.create(
      provider,
      id: 'deepseek-2',
      credentialPresent: true,
      credentialHint: '**** 2222',
    );
    await service.save(portableData, [
      MobileAgentAccount.create(provider),
      synced,
      secondConfigured,
    ]);

    final loaded = await service.load(portableData);

    expect(loaded.map((account) => account.id), [
      'synced:deepseek',
      'deepseek-2',
    ]);
    expect(loaded.every((account) => account.credentialPresent), isTrue);
  });

  test(
    'mobile syncs multiple desktop DeepSeek profiles into local accounts',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lico-mobile-deepseek-desktop-profile-sync-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final relayService = _FakeMobileRelayService()
        ..config = MobileRelayConfig.defaults().copyWith(
          pairingId: 'pair-1',
          pcClientId: 'pc-1',
          pcClientName: 'ARC Desktop',
          mobileToken: 'mobile-token',
          mobileTokenPresent: true,
          paired: true,
          authorizedProviders: const [
            MobileRelayAuthorizedProvider(
              providerId: 'deepseek',
              label: 'DeepSeek Work',
              credentialPresent: true,
              profileId: 'deepseek-work',
              source: 'desktop-model-profile',
            ),
            MobileRelayAuthorizedProvider(
              providerId: 'deepseek',
              label: 'DeepSeek Personal',
              credentialPresent: true,
              profileId: 'deepseek-personal',
              source: 'desktop-model-profile',
            ),
          ],
        );
      final controller = FutureClientController(
        portableData: PortableDataRoot(dataDirectoryOverride: directory),
        agentService: _FakeAgentService(),
        mobileRelayService: relayService,
        mobileClientRuntimePlatformOverride: true,
      );
      addTearDown(controller.dispose);

      controller.mobileRelayConfig = relayService.config;
      controller.syncMobileAgentAccountsWithDesktopRelay();

      final relayAccounts = controller.mobileAgentAccounts
          .where((account) => account.usesDesktopRelay)
          .toList(growable: false);
      expect(relayAccounts, hasLength(2));
      expect(relayAccounts.map((account) => account.relayProfileId), [
        'deepseek-work',
        'deepseek-personal',
      ]);

      await controller.syncMobileProviderCredentialsFromDesktopRelay();

      expect(relayService.credentialSyncCalls, 2);
      expect(relayService.credentialSyncProfileIds, [
        'deepseek-work',
        'deepseek-personal',
      ]);
      final localSynced = controller.mobileAgentAccounts
          .where(
            (account) =>
                account.providerId == 'deepseek' &&
                account.authSource == MobileAgentAccount.authSourceMobileSynced,
          )
          .toList(growable: false);
      expect(localSynced, hasLength(2));
      expect(localSynced.map((account) => account.relayProfileId), [
        'deepseek-work',
        'deepseek-personal',
      ]);
    },
  );

  test(
    'mobile syncs all desktop relay provider API keys after pairing',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lico-mobile-all-provider-sync-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final relayService = _FakeMobileRelayService()
        ..config = MobileRelayConfig.defaults().copyWith(
          pairingId: 'pair-1',
          pcClientId: 'pc-1',
          pcClientName: 'ARC Desktop',
          mobileToken: 'mobile-token',
          mobileTokenPresent: true,
          paired: true,
          authorizedProviders: const [
            MobileRelayAuthorizedProvider(
              providerId: 'chatgpt',
              label: 'ChatGPT',
              credentialPresent: true,
              source: 'desktop-model-profile',
            ),
            MobileRelayAuthorizedProvider(
              providerId: 'gemini',
              label: 'Gemini',
              credentialPresent: true,
              source: 'desktop-model-profile',
            ),
            MobileRelayAuthorizedProvider(
              providerId: 'kimi',
              label: 'Kimi',
              credentialPresent: true,
              source: 'desktop-model-profile',
            ),
            MobileRelayAuthorizedProvider(
              providerId: 'deepseek',
              label: 'DeepSeek',
              credentialPresent: true,
              source: 'desktop-model-profile',
            ),
          ],
        );
      final controller = FutureClientController(
        portableData: PortableDataRoot(dataDirectoryOverride: directory),
        agentService: _FakeAgentService(),
        mobileRelayService: relayService,
        mobileClientRuntimePlatformOverride: true,
      );
      addTearDown(controller.dispose);

      controller.mobileRelayConfig = relayService.config;
      controller.syncMobileAgentAccountsWithDesktopRelay();

      await controller.syncMobileProviderCredentialsFromDesktopRelay();

      expect(relayService.syncedProviderIds, ['gemini', 'kimi', 'deepseek']);
      expect(
        controller.mobileAgentAccounts.map((account) => account.providerId),
        containsAll(['chatgpt', 'gemini', 'kimi', 'deepseek']),
      );
      final syncedApiKeyAccounts = controller.mobileAgentAccounts.where(
        (account) =>
            account.provider.authKind == MobileAgentAuthKind.apiKey &&
            account.authSource == MobileAgentAccount.authSourceMobileSynced,
      );
      expect(
        syncedApiKeyAccounts.every(
          (account) => account.credentialPresent && !account.usesDesktopRelay,
        ),
        isTrue,
      );
      expect(
        syncedApiKeyAccounts.map((account) => account.providerId),
        containsAll(['gemini', 'kimi', 'deepseek']),
      );
      expect(
        controller.mobileAgentAccounts
            .singleWhere((account) => account.providerId == 'chatgpt')
            .usesDesktopRelay,
        isTrue,
      );
    },
  );

  test(
    'mobile relay executes decrypted secure mesh command through GUI binding',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lico-mobile-secure-command-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final relayService = _FakeMobileRelayService()
        ..queuedCommands = [
          const MobileRelayCommand(
            commandId: 'cmd-secure-1',
            type: 'secure_mesh.command',
            payload: {
              'secureCommandPayload': {
                'schema': 'licolite.secure-mesh.command.v1',
                'commandId': 'cmd-secure-1',
                'commandKind': 'client.activity.sync',
                'riskClass': 'read_only',
              },
              'secureCommandContext': {
                'localEndpointId': 'pc-b',
                'senderEndpointId': 'pc-a',
                'senderTrustState': 'verified',
              },
            },
            status: 'pending',
            createdAt: '2026-06-12T00:00:00.000Z',
          ),
        ];
      final controller = FutureClientController(
        portableData: PortableDataRoot(dataDirectoryOverride: directory),
        agentService: _FakeAgentService(),
        mobileRelayService: relayService,
      );
      addTearDown(controller.dispose);

      await controller.initialize();
      await controller.createMobilePairing();
      await controller.pollMobileRelayOnce();

      expect(relayService.syncCalls, 1);
      expect(relayService.commandExecuteCalls, 1);
      expect(
        relayService.lastSecureCommandPayload?['commandKind'],
        'client.activity.sync',
      );
      expect(relayService.lastSecureCommandContext?['localEndpointId'], 'pc-b');
      expect(controller.lastSecureMeshCommandExecutions, hasLength(1));
      expect(controller.lastSecureMeshCommandExecutions.single['ok'], isTrue);
      expect(controller.statusMessage, '已处理 1 条手机中转命令，执行 1 条 Secure Mesh 命令。');
    },
  );
}

class _ThrowingPortableDataRoot extends PortableDataRoot {
  @override
  Future<Directory> dataDirectory() async {
    throw Exception('boot error');
  }
}

class _FakeClipboardService extends ClientClipboardService {
  _FakeClipboardService([this.text = '']);

  final String text;
  int readCalls = 0;
  String writtenText = '';

  @override
  Future<String> readText() async {
    readCalls++;
    return text;
  }

  @override
  Future<void> writeText(String text) async {
    writtenText = text;
  }
}

Map<String, dynamic> _conversationSessionJson({
  required String id,
  required String agentId,
  required String text,
  String nativeSessionId = '',
  String createdAt = '2026-06-12T00:00:00Z',
  String updatedAt = '2026-06-12T00:00:01Z',
  String workingDirectory = '',
}) {
  return {
    'id': id,
    'agentId': agentId,
    'adapterId': agentId,
    'nativeSessionId': nativeSessionId.isEmpty ? id : nativeSessionId,
    'sourceKind': '$agentId-native-history',
    'importMode': 'precise-adapter',
    'sourceTool': agentId,
    'sourcePath': '/tmp/$agentId/history.jsonl',
    'workingDirectory': workingDirectory.isEmpty
        ? '/workspace/$agentId'
        : workingDirectory,
    'title': text,
    'createdAt': createdAt,
    'updatedAt': updatedAt,
    'native': true,
    'readOnly': true,
    'messageCount': 2,
    'messages': [
      {
        'id': 'msg-user-$id',
        'role': 'user',
        'text': text,
        'createdAt': createdAt,
      },
      {
        'id': 'msg-agent-$id',
        'role': 'agent',
        'text': '原生智能体历史响应',
        'createdAt': updatedAt,
      },
    ],
  };
}

TargetCandidate _agentArchiveTarget() {
  return TargetCandidate(
    target: 'claude-code',
    label: 'Claude Code',
    kind: 'cli',
    status: 'detected',
    configured: true,
    confidence: 1,
    adapterStatus: 'implemented',
  );
}

Iterable<String> _readSourceFiles(String root) sync* {
  final directory = Directory(root);
  if (!directory.existsSync()) {
    return;
  }

  const extensions = <String>{'.dart', '.java', '.kt', '.xml'};
  for (final entity in directory.listSync(
    recursive: true,
    followLinks: false,
  )) {
    if (entity is! File || !extensions.contains(p.extension(entity.path))) {
      continue;
    }
    yield entity.readAsStringSync();
  }
}

class _FakeAgentService extends AgentService {
  int scanTargetsCalls = 0;
  int inspectTargetCalls = 0;
  int addTargetCalls = 0;
  int planTargetCalls = 0;
  int restoreSnapshotCount = 0;
  int listSnapshotsCalls = 0;
  int listPairingsCalls = 0;
  int requestPairingCalls = 0;
  int approvePairingCalls = 0;
  int revokePairingCalls = 0;
  int listSkillsCalls = 0;
  int planSkillInstallCalls = 0;
  int applySkillInstallCalls = 0;
  int rollbackSkillInstallCalls = 0;
  int refreshMcpStatusCalls = 0;
  int updateMcpCalls = 0;
  int rollbackMcpCalls = 0;
  int requestSkillHubCalls = 0;
  int refreshSkillHubCalls = 0;
  int conversationListCalls = 0;
  int conversationStreamCalls = 0;
  int conversationAppendCalls = 0;
  int conversationDeleteCalls = 0;
  int runtimeMessageCalls = 0;
  int collectSnapshotsCalls = 0;
  int archiveJobCreateCalls = 0;
  int archiveJobStatusCalls = 0;
  int archiveJobEventsCalls = 0;
  int archiveJobDrainCalls = 0;
  int snapshotRootGetCalls = 0;
  int snapshotRootSetCalls = 0;
  int snapshotCollectionsListCalls = 0;
  int snapshotBridgeEnsureCalls = 0;
  int snapshotCuratorGetCalls = 0;
  int snapshotCuratorSetCalls = 0;
  int archiveProfilesListCalls = 0;
  int archiveRunCalls = 0;
  int archiveVerifyCalls = 0;
  int archiveReportCalls = 0;
  int localRuntimeStatusCalls = 0;
  int ensureLocalRuntimeCalls = 0;
  int startLocalRuntimeCalls = 0;
  int restartLocalRuntimeCalls = 0;
  int stopLocalRuntimeCalls = 0;
  int localRuntimeLogsCalls = 0;
  int agentUsageScanCalls = 0;
  int agentUsageReportCalls = 0;

  bool throwScanTargets = false;
  bool throwInspectTarget = false;
  bool throwAddTarget = false;
  bool throwPlanTargetConfig = false;
  bool throwRestoreSnapshot = false;
  bool throwRollbackMcp = false;
  bool throwUpdateMcp = false;
  bool throwRefreshMcpStatus = false;
  bool throwListPairings = false;
  bool throwListSkills = false;
  bool throwLocalRuntimeStatus = false;

  String restoredSnapshotId = '';
  String addedTarget = '';
  String addedConfigPath = '';
  String addedHistoryRoot = '';
  String archivedKeywords = '';
  String archiveDestinationPath = '';
  String pairedAgent = '';
  String installedSkillAgent = '';
  String installedSkillUrl = '';
  String installedSkillRoot = '';
  String installedSkillName = '';
  String rolledBackSkillInstallSnapshotId = '';
  String updatedPluginTarget = '';
  String rolledBackSnapshotId = '';
  String localRuntimeSourceRoot = '';
  String localRuntimePresetConfig = '';
  String collectedSnapshotTopic = '';
  String collectedSnapshotAgent = '';
  String agentUsageAgent = '';
  String archiveCollectionPath = '';
  String snapshotRootPath = '/tmp/lico-native-conversation-snapshots';
  String preferredSnapshotCuratorTarget = '';
  String ensuredBridgeTarget = '';
  String archiveProfileId = '';
  String runtimeSessionIdResult = '';
  String runtimeThreadIdResult = '';
  String runtimeNativeSessionIdResult = '';
  int localRuntimePort = 0;
  int localRuntimeLogsTail = 0;
  bool installedSkillOverwrite = false;
  bool installedSkillPin = false;
  Map<String, dynamic> lastRuntimeMessageRequest = const {};
  List<Map<String, dynamic>> runtimeMessageRequests = const [];

  List<TargetCandidate> scanTargetsResult = [
    TargetCandidate(
      target: 'codex',
      label: 'Codex',
      kind: 'cli',
      status: 'detected',
      configured: false,
      confidence: 0.82,
      detail: 'cli',
      manual: false,
      configPath: '/tmp/codex.toml',
      binaryPath: ['', 'opt', 'lico-test', 'bin', 'codex'].join('/'),
      adapterStatus: 'implemented',
      adapterCapabilities: _parityReadyAdapterCapabilities,
      supportedActions: [
        'mcp.plugin.status',
        'mcp.plugin.update',
        'mcp.plugin.rollback',
        'runtime.message.send',
      ],
    ),
  ];
  Map<String, dynamic> pairingResult = {'ok': true, 'status': 'requested'};
  String pairingStatus = 'requested';
  List<Map<String, dynamic>> snapshots = [
    {'snapshotId': 'snapshot-codex-1', 'target': 'codex'},
  ];
  List<Map<String, dynamic>> pairings = [
    {'agentId': 'codex', 'target': 'manual', 'status': 'requested'},
  ];
  List<Map<String, dynamic>> skills = [
    {'skillId': 'review', 'version': '1.0.0'},
  ];
  Map<String, dynamic> skillInstallPlanResult = {
    'ok': true,
    'status': 'planned',
    'skillId': 'review-helper',
    'installDir': '/tmp/codex-skills/review-helper',
    'packageDigestSha256': 'abc123',
  };
  Map<String, dynamic> skillInstallApplyResult = {
    'ok': true,
    'status': 'installed',
    'skillId': 'review-helper',
    'installDir': '/tmp/codex-skills/review-helper',
    'rollbackSnapshotId': 'skill-install-snapshot-1',
    'packageDigestSha256': 'abc123',
  };
  Map<String, dynamic> skillInstallRollbackResult = {
    'ok': true,
    'status': 'rolled_back',
    'skillId': 'review-helper',
    'snapshotId': 'skill-install-snapshot-1',
  };

  Map<String, List<Map<String, dynamic>>> conversationSessions = {};
  List<Map<String, dynamic>> snapshotCollections = const [];
  List<Map<String, dynamic>> archiveProfiles = const [
    {
      'profileId': 'licolite',
      'displayName': 'LicoLite',
      'archiveRoot': '/tmp/licolite-archive',
    },
  ];

  Map<String, dynamic> mcpStatusResult = {
    'ok': true,
    'status': 'configured',
    'target': 'codex',
  };
  Map<String, dynamic> updateResult = {'ok': true, 'status': 'updated'};
  Map<String, dynamic> rollbackResult = {'ok': true, 'status': 'rolled_back'};
  Map<String, dynamic> localRuntimeStatusResult = {
    'ok': true,
    'status': 'stopped',
    'running': false,
  };
  Map<String, dynamic> localRuntimeRunningResult = {
    'ok': true,
    'status': 'running',
    'running': true,
    'serverUrl': 'http://127.0.0.1:17329',
    'identity': {
      'identity': {
        'secretStorage': {'backend': 'macos-keychain'},
      },
    },
  };
  Map<String, dynamic> agentUsageScanResult = {
    'ok': true,
    'schemaVersion': 2,
    'generatedAt': '2026-06-28T00:00:00Z',
    'summary': {
      'agentCount': 1,
      'totalTokens': 42,
      'meteredTotalBytes': 1024,
      'estimatedHistoricalBytes': 4096,
      'attribution': 'mixed',
      'confidence': 'medium',
    },
    'agents': [
      {
        'agentId': 'codex',
        'label': 'Codex',
        'status': 'detected',
        'history': {'sessionCount': 2, 'messageCount': 4, 'totalTokens': 42},
        'traffic': {
          'meteredTotalBytes': 1024,
          'estimatedHistoricalBytes': 4096,
          'attribution': 'mixed',
        },
        'confidence': 'medium',
      },
    ],
  };
  Object? agentUsageReportsResult;

  Completer<void>? agentUsageScanGate;
  Completer<void>? agentUsageReportGate;
  Completer<void>? mcpUpdateGate;
  Completer<void>? skillBusyGate;
  Completer<void>? archiveJobDrainGate;
  int archiveJobAttempt = 1;
  Map<String, dynamic> archiveJobState = const {};
  List<List<String>> cliCalls = const [];

  @override
  Future<List<TargetCandidate>> scanTargets() async {
    scanTargetsCalls++;
    if (throwScanTargets) {
      throw Exception('scan failed');
    }
    return scanTargetsResult;
  }

  @override
  Future<Map<String, dynamic>> inspectTarget(String target) async {
    inspectTargetCalls++;
    if (throwInspectTarget) {
      throw Exception('inspect failed');
    }
    return {'target': target};
  }

  @override
  Future<Map<String, dynamic>> addTarget({
    required String target,
    String configPath = '',
    String binaryPath = '',
    String historyRoot = '',
  }) async {
    addTargetCalls++;
    if (throwAddTarget) {
      throw Exception('add failed');
    }
    addedTarget = target;
    addedConfigPath = configPath;
    addedHistoryRoot = historyRoot;
    scanTargetsCalls++;
    return {'ok': true, 'target': target};
  }

  @override
  Future<Map<String, dynamic>> planTargetConfig(String target) async {
    planTargetCalls++;
    if (throwPlanTargetConfig) {
      throw Exception('plan failed');
    }
    return {'ok': true, 'target': target, 'plan': 'noop'};
  }

  @override
  Future<Map<String, dynamic>> restoreSnapshot(String snapshotId) async {
    restoreSnapshotCount++;
    if (throwRestoreSnapshot) {
      throw Exception('restore failed');
    }
    restoredSnapshotId = snapshotId;
    return {'ok': true, 'snapshotId': snapshotId};
  }

  @override
  Future<Map<String, dynamic>> mcpPluginStatus({
    required String target,
    String configPath = '',
  }) async {
    refreshMcpStatusCalls++;
    if (throwRefreshMcpStatus) {
      throw Exception('status failed');
    }
    return mcpStatusResult;
  }

  @override
  Future<Map<String, dynamic>> updateMcpPlugin({
    required String target,
    String configPath = '',
  }) async {
    updateMcpCalls++;
    if (throwUpdateMcp) {
      throw Exception('update failed');
    }
    if (mcpUpdateGate != null) {
      await mcpUpdateGate!.future;
    }
    updatedPluginTarget = target;
    return updateResult;
  }

  @override
  Future<List<Map<String, dynamic>>> listSnapshots({String target = ''}) async {
    listSnapshotsCalls++;
    return snapshots;
  }

  @override
  Future<Map<String, dynamic>> rollbackMcpPlugin({
    required String target,
    required String snapshotId,
    String configPath = '',
  }) async {
    rollbackMcpCalls++;
    if (throwRollbackMcp) {
      throw Exception('rollback failed');
    }
    if (mcpUpdateGate != null) {
      await mcpUpdateGate!.future;
    }
    rolledBackSnapshotId = snapshotId;
    return rollbackResult;
  }

  @override
  Future<List<Map<String, dynamic>>> listPairings({String agent = ''}) async {
    listPairingsCalls++;
    if (throwListPairings) {
      throw Exception('listPairings failed');
    }
    if (agent.isNotEmpty && pairedAgent.isEmpty) {
      return pairings.map((pairing) {
        final updated = Map<String, dynamic>.from(pairing);
        updated['agentId'] = agent;
        return updated;
      }).toList();
    }
    return pairings;
  }

  @override
  Future<Map<String, dynamic>> requestPairing({
    required String agent,
    String target = '',
  }) async {
    requestPairingCalls++;
    pairedAgent = agent;
    requestSkillHubCalls++;
    pairingStatus = 'requested';
    return {...pairingResult, 'agent': agent};
  }

  @override
  Future<Map<String, dynamic>> approvePairing({required String agent}) async {
    approvePairingCalls++;
    pairedAgent = agent;
    pairingStatus = 'approved';
    return {...pairingResult, 'status': pairingStatus};
  }

  @override
  Future<Map<String, dynamic>> revokePairing({required String agent}) async {
    revokePairingCalls++;
    if (skillBusyGate != null) {
      await skillBusyGate!.future;
    }
    pairingStatus = 'revoked';
    return {...pairingResult, 'status': pairingStatus};
  }

  @override
  Future<List<Map<String, dynamic>>> listSkills({required String agent}) async {
    listSkillsCalls++;
    if (throwListSkills) {
      throw Exception('listSkills failed');
    }
    if (skillHubPairingsRequiresRefresh) {
      return [];
    }
    return skills;
  }

  @override
  Future<Map<String, dynamic>> planSkillInstall({
    required String agent,
    String url = '',
    String sourcePath = '',
    String installRoot = '',
    String name = '',
    bool overwrite = false,
  }) async {
    planSkillInstallCalls++;
    installedSkillAgent = agent;
    installedSkillUrl = url;
    installedSkillRoot = installRoot;
    installedSkillName = name;
    installedSkillOverwrite = overwrite;
    return skillInstallPlanResult;
  }

  @override
  Future<Map<String, dynamic>> applySkillInstall({
    required String agent,
    String url = '',
    String sourcePath = '',
    String installRoot = '',
    String name = '',
    bool overwrite = false,
    bool pin = false,
  }) async {
    applySkillInstallCalls++;
    installedSkillAgent = agent;
    installedSkillUrl = url;
    installedSkillRoot = installRoot;
    installedSkillName = name;
    installedSkillOverwrite = overwrite;
    installedSkillPin = pin;
    skills = [
      {
        'skillId': skillInstallApplyResult['skillId'],
        'version': '1.2.3',
        'protocolStatus': 'installed',
      },
    ];
    return skillInstallApplyResult;
  }

  @override
  Future<Map<String, dynamic>> rollbackSkillInstall({
    required String agent,
    required String snapshotId,
  }) async {
    rollbackSkillInstallCalls++;
    rolledBackSkillInstallSnapshotId = snapshotId;
    skills = const [];
    return {
      ...skillInstallRollbackResult,
      'agentId': agent,
      'snapshotId': snapshotId,
    };
  }

  bool skillHubPairingsRequiresRefresh = false;

  @override
  Future<Map<String, dynamic>> localRuntimeStatus() async {
    localRuntimeStatusCalls++;
    if (throwLocalRuntimeStatus) {
      throw Exception('local runtime status failed');
    }
    return localRuntimeStatusResult;
  }

  @override
  Future<Map<String, dynamic>> ensureLocalRuntime({
    required String sourceRoot,
    required String presetConfig,
    int port = 17328,
    bool rebuild = false,
  }) async {
    ensureLocalRuntimeCalls++;
    localRuntimeSourceRoot = sourceRoot;
    localRuntimePresetConfig = presetConfig;
    localRuntimePort = port;
    return {...localRuntimeRunningResult, 'rebuild': rebuild};
  }

  @override
  Future<Map<String, dynamic>> startLocalRuntime({int port = 17328}) async {
    startLocalRuntimeCalls++;
    localRuntimePort = port;
    return localRuntimeRunningResult;
  }

  @override
  Future<Map<String, dynamic>> restartLocalRuntime({int port = 17328}) async {
    restartLocalRuntimeCalls++;
    localRuntimePort = port;
    return localRuntimeRunningResult;
  }

  @override
  Future<Map<String, dynamic>> stopLocalRuntime() async {
    stopLocalRuntimeCalls++;
    localRuntimeStatusResult = {
      'ok': true,
      'status': 'stopped',
      'running': false,
    };
    return localRuntimeStatusResult;
  }

  @override
  Future<Map<String, dynamic>> localRuntimeLogs({int tail = 200}) async {
    localRuntimeLogsCalls++;
    localRuntimeLogsTail = tail;
    return {
      'ok': true,
      'lines': ['line-a', 'line-b'],
    };
  }

  @override
  Stream<Map<String, dynamic>> streamCliJsonLines(List<String> args) async* {
    cliCalls = [...cliCalls, List<String>.from(args)];
    if (args.length >= 2 && args[0] == 'conversations' && args[1] == 'stream') {
      conversationStreamCalls++;
      for (final session in _conversationSessionPage(args)) {
        await Future<void>.delayed(Duration.zero);
        yield {'event': 'session', 'ok': true, 'session': session};
      }
      yield {'event': 'done', 'ok': true};
      return;
    }
    throw Exception('unsupported stream command: ${args.join(' ')}');
  }

  @override
  Future<Map<String, dynamic>> runCliWithStdin(
    List<String> args,
    String stdinText,
  ) async {
    cliCalls = [...cliCalls, List<String>.from(args)];
    expect(args, ['agent', 'message', 'send', '--stdin-json', 'true']);
    final decoded = jsonDecode(stdinText);
    if (decoded is! Map<String, dynamic>) {
      throw Exception('runtime message stdin must be a JSON object');
    }
    runtimeMessageCalls++;
    lastRuntimeMessageRequest = Map<String, dynamic>.from(decoded);
    runtimeMessageRequests = [
      ...runtimeMessageRequests,
      Map<String, dynamic>.from(decoded),
    ];
    final sessionId = runtimeSessionIdResult.isNotEmpty
        ? runtimeSessionIdResult
        : (decoded['sessionId'] ?? '').toString().isNotEmpty
        ? decoded['sessionId'].toString()
        : 'native-${decoded['agent']}-$runtimeMessageCalls';
    final threadId = runtimeThreadIdResult.isNotEmpty
        ? runtimeThreadIdResult
        : sessionId;
    final nativeSessionId = runtimeNativeSessionIdResult.isNotEmpty
        ? runtimeNativeSessionIdResult
        : threadId;
    return {
      'ok': true,
      'mode': 'runtime-adapter',
      'adapterId': (decoded['agent'] ?? 'codex').toString(),
      'runtimeProtocol': 'codex-app-server',
      'sessionId': sessionId,
      'threadId': threadId,
      'nativeSessionId': nativeSessionId,
      'effective': {
        'model': decoded['model'],
        'reasoningEffort': decoded['reasoningEffort'],
      },
    };
  }

  @override
  Future<Map<String, dynamic>> runCli(List<String> args) async {
    cliCalls = [...cliCalls, List<String>.from(args)];
    if (args.length >= 2 && args[0] == 'agent-usage') {
      switch (args[1]) {
        case 'scan':
          agentUsageScanCalls++;
          agentUsageAgent = _argValue(args, '--agent');
          final scanGate = agentUsageScanGate;
          if (scanGate != null) {
            await scanGate.future;
          }
          return agentUsageScanResult;
        case 'report':
          agentUsageReportCalls++;
          final reportGate = agentUsageReportGate;
          if (reportGate != null) {
            await reportGate.future;
          }
          return {
            'ok': true,
            'schemaVersion': 2,
            'reports': agentUsageReportsResult ?? [agentUsageScanResult],
          };
      }
    }
    if (args.length >= 2 && args.first == 'conversations') {
      switch (args[1]) {
        case 'list':
          conversationListCalls++;
          return {'ok': true, 'sessions': _conversationSessionPage(args)};
        case 'append':
          conversationAppendCalls++;
          final agent = _argValue(args, '--agent');
          final label = _argValue(args, '--agent-label', fallback: agent);
          final text = _argValue(args, '--text').trim();
          final sessionId = _argValue(
            args,
            '--session-id',
            fallback: 'session-$conversationAppendCalls',
          );
          final session = _conversationSession(
            id: sessionId,
            agentId: agent,
            agentLabel: label,
            text: text,
          );
          conversationSessions = {
            ...conversationSessions,
            agent: [
              session,
              ...(conversationSessions[agent] ?? const []).where(
                (item) => item['id'] != sessionId,
              ),
            ],
          };
          return {'ok': true, 'session': session};
        case 'delete':
          conversationDeleteCalls++;
          final agent = _argValue(args, '--agent');
          final sessionId = _argValue(args, '--session-id');
          conversationSessions = {
            ...conversationSessions,
            agent: (conversationSessions[agent] ?? const [])
                .where((item) => item['id'] != sessionId)
                .toList(),
          };
          return {'ok': true};
      }
    }
    if (args.isNotEmpty && args.first == 'snapshots') {
      if (args.length >= 2 && args[1] == 'collect') {
        collectSnapshotsCalls++;
        collectedSnapshotTopic = _argValue(args, '--topic');
        collectedSnapshotAgent = _argValue(args, '--agent');
        snapshotCollections = [
          {
            'topic': collectedSnapshotTopic,
            'topicKey': collectedSnapshotTopic.replaceAll(' ', '-'),
            'state': 'materialized',
            'conversationCount': 1,
          },
        ];
        return {
          'ok': true,
          'status': 'materialized',
          'topic': collectedSnapshotTopic,
          'selectedCount': 1,
        };
      }
      if (args.length >= 3 && args[1] == 'root' && args[2] == 'get') {
        snapshotRootGetCalls++;
        return {
          'ok': true,
          'snapshotRoot': snapshotRootPath,
          'mode': 'default',
        };
      }
      if (args.length >= 3 && args[1] == 'root' && args[2] == 'set') {
        snapshotRootSetCalls++;
        snapshotRootPath = _argValue(args, '--path');
        return {'ok': true, 'status': 'set', 'snapshotRoot': snapshotRootPath};
      }
      if (args.length >= 3 && args[1] == 'collections' && args[2] == 'list') {
        snapshotCollectionsListCalls++;
        return {'ok': true, 'collections': snapshotCollections};
      }
      if (args.length >= 3 && args[1] == 'profiles' && args[2] == 'list') {
        archiveProfilesListCalls++;
        return {'ok': true, 'profiles': archiveProfiles};
      }
      if (args.length >= 4 && args[1] == 'archive' && args[2] == 'jobs') {
        switch (args[3]) {
          case 'create':
            archiveJobCreateCalls++;
            archivedKeywords = _argValue(args, '--keywords');
            archiveDestinationPath = _argValue(args, '--path');
            archiveJobState = _archiveJob(status: 'queued', attempt: 0);
            return archiveJobState;
          case 'drain':
            archiveJobDrainCalls++;
            if (archiveJobDrainGate != null) {
              await archiveJobDrainGate!.future;
            }
            snapshotCollections = [
              {
                'topic': archivedKeywords,
                'topicKey': archivedKeywords.replaceAll(' ', '-'),
                'state': 'archived',
                'conversationCount': 2,
              },
            ];
            archiveJobState = _archiveJob(
              status: 'completed',
              attempt: archiveJobAttempt,
            );
            return {
              'ok': true,
              'status': 'drained',
              'processed': 1,
              'completed': 1,
              'failed': 0,
              'deferred': 0,
              'jobs': [
                {'jobId': 'archive-job-1', 'outcome': archiveJobState},
              ],
            };
          case 'status':
            archiveJobStatusCalls++;
            return archiveJobState.isEmpty
                ? _archiveJob(status: 'queued', attempt: 0)
                : archiveJobState;
          case 'events':
            archiveJobEventsCalls++;
            final job = archiveJobState.isEmpty
                ? _archiveJob(status: 'queued', attempt: 0)
                : archiveJobState;
            return {
              'ok': true,
              'jobId': 'archive-job-1',
              'events': job['events'],
            };
        }
      }
      if (args.length >= 3 && args[1] == 'archive' && args[2] == 'run') {
        archiveRunCalls++;
        archiveProfileId = _argValue(args, '--profile');
        return {
          'ok': true,
          'status': 'materialized',
          'mode': 'conversation-archive',
          'profileId': archiveProfileId,
          'indexCount': 2,
          'selectedCount': 2,
          'validation': {'healthStatus': 'ok', 'errorCount': 0},
        };
      }
      if (args.length >= 3 && args[1] == 'archive' && args[2] == 'verify') {
        archiveVerifyCalls++;
        archiveProfileId = _argValue(args, '--profile');
        final collectionPath = _argValue(args, '--collection-path');
        return {
          'ok': true,
          'mode': 'conversation-archive-verify',
          'profileId': archiveProfileId,
          if (collectionPath.isNotEmpty) 'collectionPath': collectionPath,
          'validation': {'healthStatus': 'ok', 'errorCount': 0},
        };
      }
      if (args.length >= 3 && args[1] == 'archive' && args[2] == 'report') {
        archiveReportCalls++;
        archiveProfileId = _argValue(args, '--profile');
        return {
          'ok': true,
          'mode': 'conversation-archive-report',
          'profileId': archiveProfileId,
          'indexCount': 2,
          'validation': {'healthStatus': 'ok', 'errorCount': 0},
        };
      }
      if (args.length >= 3 && args[1] == 'curator' && args[2] == 'get') {
        snapshotCuratorGetCalls++;
        return {
          'ok': true,
          'configured': preferredSnapshotCuratorTarget.isNotEmpty,
          'preferredSnapshotCurator': preferredSnapshotCuratorTarget.isEmpty
              ? null
              : {'target': preferredSnapshotCuratorTarget},
        };
      }
      if (args.length >= 3 && args[1] == 'curator' && args[2] == 'set') {
        snapshotCuratorSetCalls++;
        if (_argValue(args, '--clear') == 'true') {
          preferredSnapshotCuratorTarget = '';
          return {
            'ok': true,
            'status': 'cleared',
            'preferredSnapshotCurator': null,
          };
        }
        preferredSnapshotCuratorTarget = _argValue(args, '--target');
        return {
          'ok': true,
          'status': 'set',
          'preferredSnapshotCurator': {
            'target': preferredSnapshotCuratorTarget,
          },
        };
      }
      if (args.length >= 3 && args[1] == 'bridge' && args[2] == 'ensure') {
        snapshotBridgeEnsureCalls++;
        ensuredBridgeTarget = _argValue(args, '--target');
        return {
          'ok': true,
          'status': 'verified',
          'target': ensuredBridgeTarget,
        };
      }
    }
    return {'ok': true};
  }

  String _argValue(List<String> args, String flag, {String fallback = ''}) {
    final index = args.indexOf(flag);
    if (index < 0 || index + 1 >= args.length) {
      return fallback;
    }
    return args[index + 1];
  }

  List<Map<String, dynamic>> _conversationSessionPage(List<String> args) {
    final agent = _argValue(args, '--agent');
    final offset =
        int.tryParse(_argValue(args, '--offset', fallback: '0')) ?? 0;
    final limit = int.tryParse(_argValue(args, '--limit'));
    final source =
        conversationSessions[agent] ?? const <Map<String, dynamic>>[];
    final safeOffset = offset < 0 ? 0 : offset;
    final skipped = source.skip(safeOffset);
    return (limit == null || limit <= 0 ? skipped : skipped.take(limit)).toList(
      growable: false,
    );
  }

  Map<String, dynamic> _archiveJob({
    required String status,
    required int attempt,
  }) {
    final events = <Map<String, dynamic>>[
      {
        'sequence': 1,
        'jobId': 'archive-job-1',
        'type': 'archive.scan.completed',
        'phase': 'queued',
        'status': 'queued',
        'attempt': 0,
      },
      if (attempt > 1)
        {
          'sequence': 2,
          'jobId': 'archive-job-1',
          'type': 'archive.retry.scheduled',
          'phase': 'retry_scheduled',
          'status': 'retry_scheduled',
          'attempt': 1,
        },
      if (status == 'completed')
        {
          'sequence': 3,
          'jobId': 'archive-job-1',
          'type': 'archive.completed',
          'phase': 'completed',
          'status': 'completed',
          'attempt': attempt,
        },
    ];
    return {
      'ok': true,
      'jobId': 'archive-job-1',
      'request': {'keywords': archivedKeywords, 'path': archiveDestinationPath},
      'status': status,
      'phase': status,
      'attempt': attempt,
      'maxAttempts': 2,
      'targetScan': {
        'ok': true,
        'source': 'target-adapters',
        'candidates': scanTargetsResult
            .map((target) => target.toJson())
            .toList(),
      },
      'targetScanSummary': {
        'source': 'target-adapters',
        'clientCount': scanTargetsResult.length,
        'detectedCount': scanTargetsResult
            .where((target) => target.status != 'not-detected')
            .length,
        'clients': scanTargetsResult.map((target) => target.toJson()).toList(),
      },
      'archiveResult': status == 'completed'
          ? {
              'status': 'archived',
              'archiveRoot': archiveDestinationPath,
              'documentCount': 2,
              'selectedCount': 2,
              'archives': [
                {
                  'keyword': archivedKeywords,
                  'collectionPath': archiveCollectionPath.isEmpty
                      ? '$archiveDestinationPath/collection.json'
                      : archiveCollectionPath,
                  'documentCount': 2,
                  'selectedCount': 2,
                },
              ],
            }
          : {},
      'validationResult': status == 'completed'
          ? {
              'ok': true,
              'validation': {'healthStatus': 'ok', 'errorCount': 0},
            }
          : {},
      'workflow': {
        'status': status,
        'currentPhase': status,
        'attempt': attempt,
        'maxAttempts': 2,
      },
      'events': events,
      'lastError': '',
    };
  }

  Map<String, dynamic> _conversationSession({
    required String id,
    required String agentId,
    required String agentLabel,
    required String text,
  }) {
    return {
      'id': id,
      'agentId': agentId,
      'title': text,
      'createdAt': '2026-06-12T00:00:00Z',
      'updatedAt': '2026-06-12T00:00:01Z',
      'messages': [
        {
          'id': 'msg-user-$id',
          'role': 'user',
          'text': text,
          'createdAt': '2026-06-12T00:00:00Z',
        },
        {
          'id': 'msg-agent-$id',
          'role': 'agent',
          'text': '本机展示：已记录给 $agentLabel 的消息，尚未连接真实智能体运行时。',
          'createdAt': '2026-06-12T00:00:01Z',
        },
      ],
    };
  }
}

class _FakeMobileRelayService extends MobileRelayService {
  _FakeMobileRelayService();

  int createPairingCalls = 0;
  int claimPairingCalls = 0;
  int refreshPairingStatusCalls = 0;
  int syncCalls = 0;
  final List<bool> syncAllowInteractionFlags = [];
  int secureMeshStatusCalls = 0;
  final List<bool> loadConfigAuthorizeSecretsFlags = [];
  final List<bool> secureMeshStatusAuthorizeFlags = [];
  int commandExecuteCalls = 0;
  int providerMessageCalls = 0;
  int localProviderMessageCalls = 0;
  int secureAgentMessageCalls = 0;
  int secureAgentSessionListCalls = 0;
  int credentialSyncCalls = 0;
  int resetPairingCalls = 0;
  int saveProviderApiKeyCalls = 0;
  int loginOAuthCalls = 0;
  int completeOAuthCallbackCalls = 0;
  int oauthStatusCalls = 0;
  bool oauthStatusCredentialPresent = true;
  bool oauthStatusIncludeUpdatedAt = true;
  int openExternalUrlCalls = 0;
  int openWebConversationCalls = 0;
  int webSnapshotCalls = 0;
  bool credentialSyncSucceeds = true;
  bool credentialSyncPairingNotFound = false;
  int deviceTrustEvaluateCalls = 0;
  int fileRouteEvaluateCalls = 0;
  int fileReceiveDestinationEvaluateCalls = 0;
  MobileRelayConfig config = MobileRelayConfig.defaults();
  List<MobileRelayAuthorizedProvider> authorizedProvidersOnRefresh = const [];
  List<MobileRelayCommand> queuedCommands = const [];
  Object? syncError;
  Map<String, dynamic>? lastSecureCommandPayload;
  Map<String, dynamic>? lastSecureCommandContext;
  Map<String, dynamic>? lastPairingInvite;
  Map<String, dynamic>? lastDeviceTrustIdentity;
  Map<String, dynamic>? lastFileRouteManifest;
  Map<String, dynamic>? lastFileReceiveDestinationManifest;
  String lastApprovedRoot = '';
  String lastProviderId = '';
  String lastProviderText = '';
  String lastProviderModel = '';
  String lastProviderReasoningEffort = '';
  String lastLocalProviderId = '';
  String lastLocalProviderText = '';
  String lastLocalProviderModel = '';
  String lastLocalProviderReasoningEffort = '';
  String lastAgentId = '';
  String lastAgentText = '';
  String lastAgentSessionId = '';
  String lastSecureAgentSessionListAgentId = '';
  int lastSecureAgentSessionListLimit = 0;
  String lastMobileAccountId = '';
  String lastProfileId = '';
  String lastExternalUrl = '';
  String lastWebProviderId = '';
  String lastOAuthAuthSurface = '';
  String lastOAuthConversationSurface = '';
  String lastOAuthCallbackUrl = '';
  final List<String> savedMobileAccountIds = [];
  final List<String> localMessageMobileAccountIds = [];
  final List<String> localProviderTexts = [];
  final List<String> loginOAuthMobileAccountIds = [];
  final List<String> oauthStatusProviderIds = [];
  final List<String> credentialSyncMobileAccountIds = [];
  final List<String> credentialSyncProfileIds = [];
  final List<String> syncedProviderIds = [];
  final Map<String, String> credentialKindsByProvider = {};
  final Map<String, int> localProviderStatusCodesByProvider = {};
  final Map<String, List<int>> localProviderStatusCodeQueuesByProvider = {};
  final Map<String, Map<String, dynamic>> localProviderFailuresByProvider = {};
  final Map<String, List<Map<String, dynamic>>> secureAgentSessions = {};
  Map<String, dynamic>? secureAgentSessionListResult;
  Completer<Map<String, dynamic>>? loginOAuthCompleter;
  Map<String, dynamic> webSnapshotResult = {
    'ok': true,
    'snapshotPresent': false,
    'messages': const <Map<String, dynamic>>[],
  };

  @override
  Future<MobileRelayConfig> loadConfig({
    required AgentService agentService,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
    bool authorizeSecrets = false,
  }) async {
    loadConfigAuthorizeSecretsFlags.add(authorizeSecrets);
    return config;
  }

  @override
  Future<void> saveConfig({
    required AgentService agentService,
    required MobileRelayConfig config,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) async {
    this.config = config;
  }

  @override
  Future<MobileRelayConfig> configureGateway({
    required AgentService agentService,
    required bool useCustomGateway,
    required String customGatewayUrl,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) async {
    config = config.copyWith(
      useCustomGateway: useCustomGateway,
      customGatewayUrl: customGatewayUrl,
    );
    return config;
  }

  @override
  Future<MobileRelayConfig> resetPairing({
    required AgentService agentService,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) async {
    resetPairingCalls++;
    config = config.copyWith(
      pairingId: '',
      mobileToken: '',
      mobileTokenPresent: false,
      paired: false,
      relayEnabled: false,
      pairedDevices: const [],
      authorizedProviders: const [],
    );
    return config;
  }

  @override
  Future<Map<String, dynamic>> createPairing({
    required AgentService agentService,
  }) async {
    createPairingCalls++;
    config = config.copyWith(
      pairingId: 'pair-1',
      pcToken: 'pc-token',
      lastPairingCode: '',
      lastPairingExpiresAt: '',
      paired: false,
      relayEnabled: true,
    );
    return {
      'ok': true,
      'pairingId': 'pair-1',
      'pcToken': 'pc-token',
      'pairingCode': '1234-5678',
      'expiresAt': '2026-06-12T12:00:00.000Z',
      'mobileRelayPairingInvite': {
        'protocolVersion': 'licolite.mobile-relay.e2ee.v2',
        'oneTime': true,
        'gatewayUrl': licoDefaultMobileRelayGatewayUrl,
        'pairingId': 'pair-1',
        'pairingCode': '1234-5678',
        'pcSecureMesh': {'endpointId': 'pc'},
        'e2eePairingSecret': 'secret',
      },
      'pairing': {'status': 'pending'},
    };
  }

  @override
  Future<Map<String, dynamic>> claimPairing({
    required AgentService agentService,
    required Map<String, dynamic> invite,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) async {
    claimPairingCalls++;
    lastPairingInvite = invite;
    config = config.copyWith(
      pairingId: (invite['pairingId'] ?? 'pair-1').toString(),
      pcClientId: (invite['pcClientId'] ?? 'pc-1').toString(),
      pcClientName: (invite['pcClientName'] ?? 'Mac').toString(),
      mobileToken: 'mobile-token',
      paired: true,
      relayEnabled: true,
      pairedDevices: [
        MobileRelayPairedDevice(
          id: (invite['pcClientId'] ?? 'pc-1').toString(),
          label: (invite['pcClientName'] ?? 'Mac').toString(),
          pairingId: (invite['pairingId'] ?? 'pair-1').toString(),
          mobileToken: 'mobile-token',
          credentialPresent: true,
          gatewayUrl: (invite['gatewayUrl'] ?? 'https://api.licolite.app')
              .toString(),
        ),
      ],
    );
    return {
      'ok': true,
      'pairingId': config.pairingId,
      'mobileToken': 'mobile-token',
      'pairing': {
        'status': 'paired',
        'pc': {'clientName': config.pcClientName},
        'mobile': {'token': 'mobile-token'},
      },
    };
  }

  @override
  Future<Map<String, dynamic>> refreshPairingStatus({
    required AgentService agentService,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) async {
    refreshPairingStatusCalls++;
    if (authorizedProvidersOnRefresh.isNotEmpty) {
      config = config.copyWith(
        paired: true,
        relayEnabled: true,
        authorizedProviders: authorizedProvidersOnRefresh,
      );
    }
    final authorizedProviders = config.authorizedProviders
        .map((provider) => provider.toJson())
        .toList(growable: false);
    return {
      'ok': true,
      if (authorizedProviders.isNotEmpty)
        'authorizedProviders': authorizedProviders,
      'pairing': {
        'status': config.paired ? 'paired' : 'pending',
        'pc': {
          'clientId': config.pcClientId,
          'clientName': config.pcClientName,
          if (authorizedProviders.isNotEmpty)
            'authorizedProviders': authorizedProviders,
          'targets': [
            {
              'target': 'codex',
              'label': 'Codex',
              'kind': 'cli',
              'status': 'detected',
              'configured': true,
              'confidence': 0.9,
              'adapterStatus': 'implemented',
              'adapterCapabilities': _parityReadyAdapterCapabilities,
              'supportedActions': ['runtime.message.send'],
            },
          ],
        },
        'mobile': {'token': config.mobileToken},
      },
    };
  }

  @override
  Future<Map<String, dynamic>> secureMeshStatus({
    required AgentService agentService,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
    bool authorize = true,
  }) async {
    secureMeshStatusCalls++;
    secureMeshStatusAuthorizeFlags.add(authorize);
    return {
      'ok': true,
      'protocolVersion': 'licolite.secure-mesh.v1',
      'pairwiseCryptoStatus': 'pairwise-runtime-available',
      'mlsCryptoStatus': 'openmls-provider-reload-available',
      'fileCryptoStatus': 'file-aead-available',
      'commandSecurityStatus': 'command-gate-available',
      'deviceTrustStatus': 'device-trust-policy-cli-gui-available',
      'cryptoCoreStatus': 'blocked_for_production',
    };
  }

  @override
  Future<Map<String, dynamic>> syncCommands({
    required AgentService agentService,
    bool allowInteraction = true,
  }) async {
    syncCalls++;
    syncAllowInteractionFlags.add(allowInteraction);
    final error = syncError;
    if (error != null) {
      throw error;
    }
    final commands = queuedCommands;
    queuedCommands = const [];
    return {
      'ok': true,
      'commands': commands.map((command) {
        return {
          'commandId': command.commandId,
          'type': command.type,
          'payload': command.payload,
          'status': command.status,
          'createdAt': command.createdAt,
        };
      }).toList(),
      'completed': commands.map((command) {
        final agentId = (command.payload['agentId'] ?? 'codex').toString();
        final sessions = agentService is _FakeAgentService
            ? (agentService.conversationSessions[agentId] ?? const [])
            : const <Map<String, dynamic>>[];
        if (command.type == 'agent.sessions.list') {
          return {
            'command': {
              'commandId': command.commandId,
              'type': command.type,
              'payload': command.payload,
            },
            'ok': true,
            'completion': {
              'command': {
                'result': {'sessions': sessions},
              },
            },
          };
        }
        if (command.type == 'secure_mesh.envelope') {
          return {
            'command': {
              'commandId': command.commandId,
              'type': command.type,
              'payload': command.payload,
            },
            'ok': false,
            'completion': {
              'ok': false,
              'code': 'secure_mesh_endpoint_crypto_runtime_required',
            },
          };
        }
        final text = (command.payload['text'] ?? 'From phone').toString();
        return {
          'command': {
            'commandId': command.commandId,
            'type': command.type,
            'payload': command.payload,
          },
          'ok': true,
          'completion': {
            'command': {
              'result': {
                'ok': true,
                'mode': 'runtime-adapter',
                'adapterId': agentId,
                'output': text,
              },
            },
          },
        };
      }).toList(),
    };
  }

  @override
  Future<Map<String, dynamic>> executeSecureMeshCommand({
    required AgentService agentService,
    required Map<String, dynamic> payload,
    required Map<String, dynamic> context,
    String ledgerPath = '',
    String completedAt = '',
  }) async {
    commandExecuteCalls++;
    lastSecureCommandPayload = payload;
    lastSecureCommandContext = context;
    return {
      'ok': true,
      'evaluation': {'accepted': true, 'shouldExecute': true},
      'execution': {
        'outcome': 'result',
        'output': {'ok': true, 'events': const []},
      },
    };
  }

  @override
  Future<Map<String, dynamic>> sendSecureProviderMessage({
    required AgentService agentService,
    required String providerId,
    required String text,
    String model = '',
    String reasoningEffort = '',
    String profileId = '',
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) async {
    providerMessageCalls++;
    lastProviderId = providerId;
    lastProviderText = text;
    lastProviderModel = model;
    lastProviderReasoningEffort = reasoningEffort;
    lastProfileId = profileId;
    return {
      'ok': true,
      'result': {
        'openedResult': {
          'execution': {
            'outcome': 'result',
            'output': {
              'ok': true,
              'commandKind': 'provider.chat.send',
              'output': {
                'ok': true,
                'providerId': providerId,
                'content': 'DeepSeek relay reply',
                'output': 'DeepSeek relay reply',
              },
            },
          },
        },
      },
    };
  }

  @override
  Future<Map<String, dynamic>> sendSecureAgentMessage({
    required AgentService agentService,
    required String agentId,
    required String text,
    String sessionId = '',
    String model = '',
    String reasoningEffort = '',
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) async {
    secureAgentMessageCalls++;
    lastAgentId = agentId;
    lastAgentText = text;
    lastAgentSessionId = sessionId;
    final nativeSessionId = sessionId.trim().isNotEmpty
        ? sessionId.trim()
        : 'native-$agentId-relay';
    return {
      'ok': true,
      'result': {
        'openedResult': {
          'execution': {
            'outcome': 'result',
            'output': {
              'ok': true,
              'commandKind': 'agent.message.send',
              'output': {
                'ok': true,
                'agentId': agentId,
                'nativeSessionId': nativeSessionId,
                'threadId': nativeSessionId,
                'sessionId': nativeSessionId,
                'effective': {
                  'model': model.isEmpty ? null : model,
                  'reasoningEffort': reasoningEffort.isEmpty
                      ? null
                      : reasoningEffort,
                },
                'content': 'Codex relay reply',
                'output': 'Codex relay reply',
              },
            },
          },
        },
      },
    };
  }

  @override
  Future<Map<String, dynamic>> listSecureAgentSessions({
    required AgentService agentService,
    required String agentId,
    int limit = 20,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) async {
    secureAgentSessionListCalls++;
    lastSecureAgentSessionListAgentId = agentId;
    lastSecureAgentSessionListLimit = limit;
    final override = secureAgentSessionListResult;
    if (override != null) {
      return Map<String, dynamic>.from(override);
    }
    return {
      'ok': true,
      'agentId': agentId,
      'sessions': List<Map<String, dynamic>>.from(
        secureAgentSessions[agentId] ?? const [],
      ),
      'hasMore': false,
    };
  }

  @override
  Future<Map<String, dynamic>> openMobileProviderWebConversation({
    required AgentService agentService,
    required String providerId,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) async {
    openWebConversationCalls++;
    lastWebProviderId = providerId;
    return {
      'ok': true,
      'providerId': providerId,
      'mode': 'chatgpt-webview',
      'status': 'opened',
    };
  }

  @override
  Future<Map<String, dynamic>> mobileProviderWebConversationSnapshot({
    required AgentService agentService,
    required String providerId,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) async {
    webSnapshotCalls++;
    lastWebProviderId = providerId;
    return {'providerId': providerId, ...webSnapshotResult};
  }

  @override
  Future<Map<String, dynamic>> sendLocalProviderMessage({
    required AgentService agentService,
    required String providerId,
    required String text,
    String model = '',
    String reasoningEffort = '',
    String mobileAccountId = '',
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) async {
    localProviderMessageCalls++;
    lastLocalProviderId = providerId;
    lastLocalProviderText = text;
    lastLocalProviderModel = model;
    lastLocalProviderReasoningEffort = reasoningEffort;
    lastMobileAccountId = mobileAccountId;
    localMessageMobileAccountIds.add(mobileAccountId);
    localProviderTexts.add(text);
    final statusQueue = localProviderStatusCodeQueuesByProvider[providerId];
    final queuedStatusCode = statusQueue != null && statusQueue.isNotEmpty
        ? statusQueue.removeAt(0)
        : 0;
    final failedStatusCode = queuedStatusCode > 0
        ? queuedStatusCode
        : localProviderStatusCodesByProvider[providerId];
    if (failedStatusCode != null) {
      return {
        'ok': false,
        'providerId': providerId,
        'mobileAccountId': mobileAccountId,
        'status': 'oauth_chat_failed',
        'statusCode': failedStatusCode,
        'proxyMode': 'direct',
      };
    }
    final failure = localProviderFailuresByProvider[providerId];
    if (failure != null) {
      return {
        'ok': false,
        'providerId': providerId,
        'mobileAccountId': mobileAccountId,
        ...failure,
      };
    }
    return {
      'ok': true,
      'providerId': providerId,
      'content': providerId == 'deepseek'
          ? 'DeepSeek phone reply'
          : '$providerId phone reply',
      'output': providerId == 'deepseek'
          ? 'DeepSeek phone reply'
          : '$providerId phone reply',
    };
  }

  @override
  Future<Map<String, dynamic>> syncMobileProviderCredentialFromRelay({
    required AgentService agentService,
    required String providerId,
    String mobileAccountId = '',
    String profileId = '',
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) async {
    credentialSyncCalls++;
    lastProviderId = providerId;
    lastMobileAccountId = mobileAccountId;
    lastProfileId = profileId;
    credentialSyncMobileAccountIds.add(mobileAccountId);
    credentialSyncProfileIds.add(profileId);
    syncedProviderIds.add(providerId);
    if (credentialSyncPairingNotFound) {
      return {
        'ok': false,
        'providerId': providerId,
        'status': 'provider_credential_sync_create_failed',
        'detailCode': 'pairing_not_found',
        'detail': 'mobile relay pairing is not present',
      };
    }
    if (!credentialSyncSucceeds) {
      return {
        'ok': false,
        'providerId': providerId,
        'status': 'credential_sync_disabled_for_test',
      };
    }
    final credentialKind =
        credentialKindsByProvider[providerId] ??
        (profileId.toLowerCase().contains('oauth') ? 'oauth-pkce' : 'api-key');
    return {
      'ok': true,
      'providerId': providerId,
      'mobileAccountId': mobileAccountId,
      'credentialPresent': true,
      'credentialKind': credentialKind,
      'credentialHint': credentialKind.startsWith('oauth')
          ? 'OAuth'
          : '**** 4321',
      'syncedFromRelay': true,
    };
  }

  @override
  Future<Map<String, dynamic>> saveMobileProviderApiKey({
    required AgentService agentService,
    required String providerId,
    required String apiKey,
    String mobileAccountId = '',
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) async {
    saveProviderApiKeyCalls++;
    lastProviderId = providerId;
    lastMobileAccountId = mobileAccountId;
    savedMobileAccountIds.add(mobileAccountId);
    final compact = apiKey.trim();
    return {
      'ok': true,
      'providerId': providerId,
      'mobileAccountId': mobileAccountId,
      'credentialPresent': true,
      'credentialHint': compact.length <= 4
          ? '****'
          : '**** ${compact.substring(compact.length - 4)}',
    };
  }

  @override
  Future<Map<String, dynamic>> loginMobileProviderOAuth({
    required AgentService agentService,
    required String providerId,
    String mobileAccountId = '',
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) async {
    loginOAuthCalls++;
    lastProviderId = providerId;
    lastMobileAccountId = mobileAccountId;
    loginOAuthMobileAccountIds.add(mobileAccountId);
    lastOAuthAuthSurface = _oauthAuthSurface(providerId);
    lastOAuthConversationSurface = _oauthConversationSurface(providerId);
    final completer = loginOAuthCompleter;
    if (completer != null) {
      return completer.future;
    }
    return {
      'ok': true,
      'providerId': providerId,
      'mobileAccountId': mobileAccountId,
      'credentialPresent': true,
      'credentialKind': 'oauth-pkce',
      'credentialHint': 'OAuth',
      'authSurface': lastOAuthAuthSurface,
      'conversationSurface': lastOAuthConversationSurface,
    };
  }

  @override
  Future<Map<String, dynamic>> completeMobileProviderOAuthCallback({
    required AgentService agentService,
    required String providerId,
    required String callbackUrl,
    String mobileAccountId = '',
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) async {
    completeOAuthCallbackCalls++;
    lastProviderId = providerId;
    lastMobileAccountId = mobileAccountId;
    lastOAuthCallbackUrl = callbackUrl;
    return {
      'ok': true,
      'providerId': providerId,
      'mobileAccountId': mobileAccountId,
      'credentialPresent': true,
      'credentialKind': 'oauth-pkce',
      'credentialHint': 'OAuth',
      'authSurface': _oauthAuthSurface(providerId),
      'conversationSurface': _oauthConversationSurface(providerId),
    };
  }

  @override
  Future<Map<String, dynamic>> mobileProviderOAuthStatus({
    required AgentService agentService,
    required String providerId,
    String mobileAccountId = '',
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) async {
    oauthStatusCalls++;
    lastProviderId = providerId;
    lastMobileAccountId = mobileAccountId;
    oauthStatusProviderIds.add(providerId);
    lastOAuthAuthSurface = _oauthAuthSurface(providerId);
    lastOAuthConversationSurface = _oauthConversationSurface(providerId);
    return {
      'ok': true,
      'providerId': providerId,
      'mobileAccountId': mobileAccountId,
      'credentialPresent': oauthStatusCredentialPresent,
      'credentialKind': 'oauth-pkce',
      'credentialHint': 'OAuth',
      if (!oauthStatusCredentialPresent) 'status': 'oauth_credential_missing',
      'authSurface': lastOAuthAuthSurface,
      'conversationSurface': lastOAuthConversationSurface,
      if (oauthStatusIncludeUpdatedAt)
        'updatedAtEpochMillis': DateTime.now().toUtc().millisecondsSinceEpoch,
    };
  }

  @override
  Future<Map<String, dynamic>> openExternalUrl({
    required AgentService agentService,
    required String url,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) async {
    openExternalUrlCalls++;
    lastExternalUrl = url;
    return {'ok': true, 'status': 'opened'};
  }

  @override
  Future<Map<String, dynamic>> evaluateSecureMeshDeviceTrust({
    required AgentService agentService,
    required Map<String, dynamic> identity,
    Map<String, dynamic>? previousIdentity,
    String trustState = 'unverified',
    bool requireVerifiedDevice = true,
    bool allowUnverifiedReadOnly = false,
  }) async {
    deviceTrustEvaluateCalls++;
    lastDeviceTrustIdentity = identity;
    return {
      'ok': true,
      'trustState': 'unverified',
      'requestedTrustState': trustState,
      'decision': {
        'code': 'verification_required',
        'allowedForPrekey': false,
        'allowedForHighRiskCommand': false,
      },
    };
  }

  @override
  Future<Map<String, dynamic>> evaluateSecureMeshFileRoute({
    required AgentService agentService,
    required Map<String, dynamic> manifest,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) async {
    fileRouteEvaluateCalls++;
    lastFileRouteManifest = manifest;
    return {
      'ok': true,
      'route': {
        'uploadOperation': 'secure_mesh.file_chunk.upload',
        'fetchOperation': 'secure_mesh.file_chunk.fetch',
      },
    };
  }

  @override
  Future<Map<String, dynamic>> evaluateSecureMeshFileReceiveDestination({
    required AgentService agentService,
    required Map<String, dynamic> manifest,
    required String approvedRoot,
    String conflictPolicy = 'fail_if_exists',
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) async {
    fileReceiveDestinationEvaluateCalls++;
    lastFileReceiveDestinationManifest = manifest;
    lastApprovedRoot = approvedRoot;
    return {
      'ok': true,
      'receivePolicy': {
        'destinationApproved': true,
        'requiresUserApprovedRoot': true,
        'destinationPathRedacted': true,
        'conflictPolicy': conflictPolicy,
        'writeOperation': 'secure_mesh.file_receive.write',
      },
    };
  }

  String _oauthAuthSurface(String providerId) {
    return switch (providerId) {
      'chatgpt' => 'openai-chatgpt-oauth',
      _ => '$providerId-oauth',
    };
  }

  String _oauthConversationSurface(String providerId) {
    return switch (providerId) {
      'chatgpt' => 'chatgpt-codex-responses',
      _ => '$providerId-direct-chat',
    };
  }
}
