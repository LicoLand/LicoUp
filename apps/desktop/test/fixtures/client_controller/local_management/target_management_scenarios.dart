import '../support/client_controller_scenario_dependencies.dart';
import '../support/fake_agent_service.dart';

void registerClientTargetManagementScenarios() {
  test('inspect target captures failures', () async {
    final service = FakeAgentService()..throwInspectTarget = true;
    final controller = ClientController(agentService: service);
    addTearDown(controller.dispose);

    await controller.inspectTarget('codex');

    expect(controller.lastError, 'target_inspect_failed');
    expect(controller.statusMessage, 'codex 目标适配器读取失败。');
  });

  test('inspect target success updates status and result', () async {
    final service = FakeAgentService();
    final controller = ClientController(agentService: service);
    addTearDown(controller.dispose);

    await controller.inspectTarget('codex');

    expect(controller.targetInspection, {'target': 'codex'});
    expect(controller.statusMessage, '已读取 codex 目标适配器。');
    expect(controller.statusCaption, 'Target inspect');
  });

  test(
    'adds manual target using trimmed input and ignores empty names',
    () async {
      final service = FakeAgentService();
      final controller = ClientController(agentService: service);
      addTearDown(controller.dispose);

      await controller.addManualTarget(
        target: '  openclaw  ',
        configPath: ' test-data/openclaw.json ',
        historyRoot: ' test-data/openclaw-history ',
      );
      expect(service.addedTarget, 'openclaw');
      expect(service.addedConfigPath, 'test-data/openclaw.json');
      expect(service.addedHistoryRoot, 'test-data/openclaw-history');
      expect(
        service.scanBatchSlotCalls,
        AgentService.packagedScanTargetIds.length,
      );
      expect(
        controller.statusMessage,
        anyOf(contains('已添加 openclaw 手动目标。'), contains('已扫描')),
      );

      service.scanTargetsCalls = 0;
      service.scanBatchSlotCalls = 0;
      await controller.addManualTarget(target: '   ');
      expect(service.scanBatchSlotCalls, 0);
      expect(controller.lastError, isEmpty);
    },
  );

  test('adds manual target failure keeps error state', () async {
    final service = FakeAgentService()..throwAddTarget = true;
    final controller = ClientController(agentService: service);
    addTearDown(controller.dispose);

    await controller.addManualTarget(
      target: 'openclaw',
      configPath: ' test-data/openclaw.json ',
    );

    expect(controller.lastError, 'target_add_failed');
    expect(controller.statusMessage, 'openclaw 手动目标添加失败。');
    expect(controller.statusCaption, 'Targets');
  });

  test(
    'restores snapshots successfully and ignores blank snapshot ids',
    () async {
      final service = FakeAgentService();
      final controller = ClientController(agentService: service);
      addTearDown(controller.dispose);

      await controller.restoreSnapshot('snapshot-codex-1');
      expect(service.restoredSnapshotId, 'snapshot-codex-1');
      expect(controller.snapshotRestoreResult?['ok'], isTrue);

      await controller.restoreSnapshot('   ');
      expect(service.restoreSnapshotCount, 1);
    },
  );

  test('restores snapshot handles client failure', () async {
    final service = FakeAgentService()..throwRestoreSnapshot = true;
    final controller = ClientController(agentService: service);
    addTearDown(controller.dispose);

    await controller.restoreSnapshot('snapshot-codex-1');

    expect(controller.lastError, 'snapshot_restore_failed');
    expect(controller.statusMessage, '配置快照恢复失败。');
  });
}
