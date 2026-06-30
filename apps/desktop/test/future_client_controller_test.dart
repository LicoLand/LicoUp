import 'dart:async';
import 'dart:io';

import 'package:flutter_client/src/controllers/future_client_controller.dart';
import 'package:flutter_client/src/models/future_client_models.dart';
import 'package:flutter_client/src/services/agent_service.dart';
import 'package:flutter_client/src/services/local_runtime_preferences_service.dart';
import 'package:flutter_client/src/services/mobile_relay_service.dart';
import 'package:flutter_client/src/services/portable_data_root.dart';
import 'package:flutter_client/src/ui/appearance_preset_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

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

      final controller = FutureClientController(
        portableData: PortableDataRoot(dataDirectoryOverride: directory),
        agentService: _FakeAgentService(),
      );
      addTearDown(controller.dispose);

      await controller.initialize();

      expect(controller.initialized, isTrue);
      expect(controller.portableDataPath, directory.path);
      expect(
        await File('${directory.path}/.lico-workspace.json').exists(),
        isTrue,
      );
    },
  );

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
      localRuntimePreferencesService: const LocalRuntimePreferencesService(),
    );
    addTearDown(controller.dispose);

    await controller.initialize();
    await controller.ensureLocalRuntime(port: 17329);

    expect(service.ensureLocalRuntimeCalls, 1);
    expect(service.localRuntimePort, 17329);
    expect(controller.localRuntimePreferences.port, 17329);
    expect(controller.localRuntimeState?['running'], isTrue);
    expect(controller.statusMessage, '本地运行时已就绪。');
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

  test('agent usage scan updates controller state', () async {
    final directory = await Directory.systemTemp.createTemp('lico-usage-');
    addTearDown(() => directory.delete(recursive: true));
    final service = _FakeAgentService();
    final controller = FutureClientController(
      portableData: PortableDataRoot(dataDirectoryOverride: directory),
      agentService: service,
    );
    addTearDown(controller.dispose);

    await controller.scanAgentUsage(observeNetwork: true);

    expect(service.agentUsageScanCalls, 1);
    expect(service.agentUsageObserveMs, 1500);
    expect(controller.agentUsageReport?.totalTokens, 42);
    expect(controller.agentUsageReport?.agent('codex')?.attribution, 'mixed');
    expect(controller.isObservingAgentNetwork, isFalse);
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

  test('scanTargets selects an agent and loads native agent history', () async {
    final directory = await Directory.systemTemp.createTemp('lico-agent-chat-');
    addTearDown(() => directory.delete(recursive: true));
    final service = _FakeAgentService()
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
    expect(controller.selectedConversationAgentId, 'codex');
    expect(controller.selectedConversationSessions, hasLength(1));
    expect(controller.selectedConversationSession?.messages, hasLength(2));
    expect(
      controller.selectedConversationSession?.messages.first.text,
      'Hello from native Codex history',
    );
    expect(controller.statusMessage, contains('已读取 1 条 codex 原生历史'));
  });

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
      await controller.sendConversationMessage('  Hello Codex  ');

      expect(service.runtimeMessageCalls, 1);
      expect(service.lastRuntimeMessageArgs, [
        'agent',
        'message',
        'send',
        '--agent',
        'codex',
        '--text',
        'Hello Codex',
        '--session-id',
        'native-codex-1',
      ]);
      expect(service.conversationAppendCalls, 0);
      expect(controller.selectedConversationSessions, hasLength(1));
      expect(controller.lastError, isEmpty);
      expect(controller.statusMessage, '已通过 Codex runtime adapter 发送消息。');
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
    expect(controller.statusMessage, 'Skill Hub 操作失败。');
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

  test('handles model forwarding success and busy guard', () async {
    final service = _FakeAgentService();
    final controller = FutureClientController(agentService: service);
    addTearDown(controller.dispose);

    await controller.refreshModelProfiles();
    expect(controller.modelProfiles, isNotEmpty);

    await controller.saveCommandModelProfile(
      profileId: 'local-echo',
      command: 'cat',
    );
    expect(controller.modelProfiles.single['id'], 'local-echo');

    await controller.forwardModelText(profileId: 'local-echo', text: 'hello');
    expect(controller.modelForwardingResult?['output'], 'hello');

    service.modelBusyGate = Completer<void>();
    unawaited(
      controller.saveCommandModelProfile(
        profileId: 'local-echo',
        command: 'cat',
      ),
    );
    await Future<void>.delayed(Duration.zero);
    await controller.forwardModelText(profileId: 'local-echo', text: 'skip');
    expect(service.saveCommandCount, 2);

    service.modelBusyGate!.complete();
    await Future<void>.delayed(Duration.zero);
  });

  test('reports model forwarding failure', () async {
    final service = _FakeAgentService()..throwForwardText = true;
    final controller = FutureClientController(agentService: service);
    addTearDown(controller.dispose);

    await controller.forwardModelText(profileId: 'local-echo', text: 'hello');
    expect(controller.lastError, contains('forward failed'));
    expect(controller.statusMessage, 'Model Forwarding 操作失败。');
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

    expect(relayService.secureMeshStatusCalls, 1);
    expect(
      controller.secureMeshStatus?['protocolVersion'],
      'licolite.secure-mesh.v1',
    );
    expect(relayService.createPairingCalls, 1);
    expect(controller.mobileRelayConfig.lastPairingCode, '1234-5678');
    expect(controller.mobileRelayConfig.hasPairing, isTrue);

    await controller.pollMobileRelayOnce();

    expect(relayService.syncCalls, 1);
    expect(
      controller.lastMobileRelayCommands.single.type,
      'secure_mesh.envelope',
    );
  });

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

    expect(relayService.secureMeshStatusCalls, 2);
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
      expect(controller.secureMeshDeviceTrustPolicy?['trustState'], 'verified');
      expect(
        controller.secureMeshDeviceTrustPolicy?['decision']?['code'],
        'trusted',
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

Map<String, dynamic> _conversationSessionJson({
  required String id,
  required String agentId,
  required String text,
}) {
  return {
    'id': id,
    'agentId': agentId,
    'adapterId': agentId,
    'nativeSessionId': id,
    'sourceKind': '$agentId-native-history',
    'importMode': 'precise-adapter',
    'sourceTool': agentId,
    'sourcePath': '/tmp/$agentId/history.jsonl',
    'title': text,
    'createdAt': '2026-06-12T00:00:00Z',
    'updatedAt': '2026-06-12T00:00:01Z',
    'native': true,
    'readOnly': true,
    'messageCount': 2,
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
        'text': '原生智能体历史响应',
        'createdAt': '2026-06-12T00:00:01Z',
      },
    ],
  };
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
  int listModelProfilesCalls = 0;
  int saveCommandCount = 0;
  int forwardTextCount = 0;
  int refreshMcpStatusCalls = 0;
  int updateMcpCalls = 0;
  int rollbackMcpCalls = 0;
  int requestSkillHubCalls = 0;
  int refreshSkillHubCalls = 0;
  int conversationListCalls = 0;
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
  bool throwForwardText = false;
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
  String collectedSnapshotTopic = '';
  String collectedSnapshotAgent = '';
  String archiveCollectionPath = '';
  String snapshotRootPath = '/tmp/lico-native-conversation-snapshots';
  String preferredSnapshotCuratorTarget = '';
  String ensuredBridgeTarget = '';
  String archiveProfileId = '';
  int localRuntimePort = 0;
  int localRuntimeLogsTail = 0;
  int agentUsageObserveMs = 0;
  bool installedSkillOverwrite = false;
  bool installedSkillPin = false;
  List<String> lastRuntimeMessageArgs = const [];

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
      adapterStatus: 'implemented',
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

  List<Map<String, dynamic>> modelProfiles = [
    {'id': 'local-echo', 'provider': 'command', 'command': 'cat'},
  ];
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

  Completer<void>? mcpUpdateGate;
  Completer<void>? modelBusyGate;
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
    if (modelBusyGate != null) {
      await modelBusyGate!.future;
    }
    pairingStatus = 'requested';
    return {...pairingResult, 'agent': agent};
  }

  @override
  Future<Map<String, dynamic>> approvePairing({required String agent}) async {
    approvePairingCalls++;
    pairedAgent = agent;
    pairingStatus = 'approved';
    if (modelBusyGate != null) {
      await modelBusyGate!.future;
    }
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
  Future<List<Map<String, dynamic>>> listModelProfiles() async {
    listModelProfilesCalls++;
    return modelProfiles;
  }

  @override
  Future<Map<String, dynamic>> saveCommandModelProfile({
    required String profileId,
    required String command,
  }) async {
    saveCommandCount++;
    if (modelBusyGate != null) {
      await modelBusyGate!.future;
    }
    if (command == 'fail') {
      throw Exception('save failed');
    }
    modelProfiles = [
      {'id': profileId, 'provider': 'command', 'command': command},
    ];
    return {'ok': true, 'status': 'saved', 'profile': profileId};
  }

  @override
  Future<Map<String, dynamic>> forwardText({
    required String profileId,
    required String text,
  }) async {
    forwardTextCount++;
    if (throwForwardText) {
      throw Exception('forward failed');
    }
    if (modelBusyGate != null) {
      await modelBusyGate!.future;
    }
    return {'ok': true, 'mode': 'thin-forward', 'output': text};
  }

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
    int port = 17328,
    bool rebuild = false,
  }) async {
    ensureLocalRuntimeCalls++;
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
  Future<Map<String, dynamic>> runCli(List<String> args) async {
    cliCalls = [...cliCalls, List<String>.from(args)];
    if (args.length >= 2 && args[0] == 'agent-usage') {
      switch (args[1]) {
        case 'scan':
          agentUsageScanCalls++;
          agentUsageObserveMs =
              int.tryParse(_argValue(args, '--observe-ms', fallback: '0')) ?? 0;
          return agentUsageScanResult;
        case 'report':
          agentUsageReportCalls++;
          return {
            'ok': true,
            'reports': [agentUsageScanResult],
          };
      }
    }
    if (args.length >= 3 &&
        args[0] == 'agent' &&
        args[1] == 'message' &&
        args[2] == 'send') {
      runtimeMessageCalls++;
      lastRuntimeMessageArgs = List<String>.from(args);
      return {
        'ok': true,
        'mode': 'runtime-adapter',
        'adapterId': _argValue(args, '--agent', fallback: 'codex'),
        'runtimeProtocol': 'codex-cli-exec',
      };
    }
    if (args.length >= 2 && args.first == 'conversations') {
      switch (args[1]) {
        case 'list':
          conversationListCalls++;
          final agent = _argValue(args, '--agent');
          return {
            'ok': true,
            'sessions': conversationSessions[agent] ?? const [],
          };
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
  int syncCalls = 0;
  int secureMeshStatusCalls = 0;
  int commandExecuteCalls = 0;
  int deviceTrustEvaluateCalls = 0;
  int fileRouteEvaluateCalls = 0;
  MobileRelayConfig config = MobileRelayConfig.defaults();
  List<MobileRelayCommand> queuedCommands = const [];
  Map<String, dynamic>? lastSecureCommandPayload;
  Map<String, dynamic>? lastSecureCommandContext;
  Map<String, dynamic>? lastDeviceTrustIdentity;
  Map<String, dynamic>? lastFileRouteManifest;

  @override
  Future<MobileRelayConfig> loadConfig({
    required AgentService agentService,
  }) async {
    return config;
  }

  @override
  Future<void> saveConfig({
    required AgentService agentService,
    required MobileRelayConfig config,
  }) async {
    this.config = config;
  }

  @override
  Future<MobileRelayConfig> configureGateway({
    required AgentService agentService,
    required bool useCustomGateway,
    required String customGatewayUrl,
  }) async {
    config = config.copyWith(
      useCustomGateway: useCustomGateway,
      customGatewayUrl: customGatewayUrl,
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
      lastPairingCode: '1234-5678',
      lastPairingExpiresAt: '2026-06-12T12:00:00.000Z',
      paired: false,
      relayEnabled: true,
    );
    return {
      'ok': true,
      'pairingId': 'pair-1',
      'pcToken': 'pc-token',
      'pairingCode': '1234-5678',
      'expiresAt': '2026-06-12T12:00:00.000Z',
      'pairing': {'status': 'pending'},
    };
  }

  @override
  Future<Map<String, dynamic>> secureMeshStatus({
    required AgentService agentService,
  }) async {
    secureMeshStatusCalls++;
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
  }) async {
    syncCalls++;
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
      'trustState': trustState,
      'decision': {'code': 'trusted'},
    };
  }

  @override
  Future<Map<String, dynamic>> evaluateSecureMeshFileRoute({
    required AgentService agentService,
    required Map<String, dynamic> manifest,
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
}
