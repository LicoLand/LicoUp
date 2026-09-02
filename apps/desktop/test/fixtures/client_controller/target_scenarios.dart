import 'package:path/path.dart' as p;

import 'support/client_controller_scenario_dependencies.dart';
import 'support/client_controller_scenario_environment.dart';
import 'support/client_controller_scenario_json.dart';
import 'support/fake_agent_service.dart';

void registerClientTargetScenarios() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('scanTargets captures failed scans and clears busy flag', () async {
    final directory = await Directory.systemTemp.createTemp(
      'lico-failed-target-scan-',
    );
    addTearDown(() => deleteTempDirectory(directory));
    final service = FakeAgentService()..throwScanTargets = true;
    final controller = ClientController(
      portableData: PortableDataRoot(dataDirectoryOverride: directory),
      agentService: service,
    );
    addTearDown(controller.dispose);

    await controller.scanTargets();

    expect(controller.isScanningTargets, isFalse);
    expect(controller.scannedTargets, isEmpty);
    expect(controller.lastError, 'target_scan_failed');
    expect(controller.statusMessage, '目标适配器扫描失败。');
    expect(controller.statusCaption, 'Targets');
  });

  test(
    'scanTargets continues when the acceleration cache is unavailable',
    () async {
      final service = FakeAgentService();
      final controller = ClientController(
        portableData: ThrowingPortableDataRoot(),
        agentService: service,
      );
      addTearDown(controller.dispose);

      await controller.scanTargets();

      expect(
        service.scanBatchSlotCalls,
        AgentService.packagedScanTargetIds.length,
      );
      expect(controller.scannedTargets.map((target) => target.target), [
        'codex',
      ]);
      expect(controller.lastError, isEmpty);
      expect(controller.isScanningTargets, isFalse);
    },
  );

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
      final controller = ClientController(
        portableData: PortableDataRoot(dataDirectoryOverride: directory),
        agentService: FakeAgentService(),
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
        'claude-code',
        'codex',
        'opencode',
      ]);

      await controller.reorderConversationAgentTabs(visibleTabs, 2, 0);

      expect(controller.agentTabOrder, ['opencode', 'claude-code', 'codex']);
      expect(
        await File(
          p.join(directory.path, 'client-state', 'agent-tab-order.json'),
        ).exists(),
        isTrue,
      );
      expect(
        controller
            .orderedConversationTargets(targets)
            .map((target) => target.target),
        ['opencode', 'claude-code', 'codex'],
      );

      await controller.reorderConversationAgentTabs(
        controller.orderedConversationTargets(targets),
        0,
        3,
      );

      expect(controller.agentTabOrder, ['claude-code', 'codex', 'opencode']);

      final reloaded = ClientController(
        portableData: PortableDataRoot(dataDirectoryOverride: directory),
        agentService: FakeAgentService()..scanTargetsResult = targets,
      );
      addTearDown(reloaded.dispose);

      await reloaded.initialize();

      expect(reloaded.agentTabOrder, ['claude-code', 'codex', 'opencode']);
      expect(
        reloaded
            .orderedConversationTargets(targets)
            .map((target) => target.target),
        ['claude-code', 'codex', 'opencode'],
      );
    },
  );

  test('scanTargets loads native agent history without selecting it', () async {
    final directory = await Directory.systemTemp.createTemp('lico-agent-chat-');
    addTearDown(() => directory.delete(recursive: true));
    final service = FakeAgentService()
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
          configPath: 'test-data/codex.toml',
          adapterStatus: 'implemented',
          adapterCapabilities: parityReadyAdapterCapabilities,
          supportedActions: ['runtime.message.send'],
        ),
      ]
      ..conversationSessions['codex'] = [
        conversationSessionJson(
          id: 'native-codex-1',
          agentId: 'codex',
          text: 'Hello from native Codex history',
        ),
      ];
    final controller = ClientController(
      portableData: PortableDataRoot(dataDirectoryOverride: directory),
      agentService: service,
    );
    addTearDown(controller.dispose);

    await controller.scanTargets();
    expect(controller.selectedConversationAgentId, isEmpty);
    await controller.selectConversationAgent('codex');
    controller.selectConversationSession('native-codex-1');

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
}
