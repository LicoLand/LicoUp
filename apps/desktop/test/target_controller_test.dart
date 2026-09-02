import 'dart:async';

import 'package:licoup/src/application/features/targets/controller/target_controller.dart';
import 'package:licoup/src/application/features/targets/policy/target_policy.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/contracts/target_management.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('incremental plan skips known targets unless explicitly rescanned', () {
    final known = [_target('codex')];
    expect(
      TargetPolicy.incrementalScanIds(
        packagedIds: const ['codex', 'claude-code', 'opencode'],
        currentTargets: known,
        rescanKnown: false,
      ),
      ['claude-code', 'opencode'],
    );
    expect(
      TargetPolicy.incrementalScanIds(
        packagedIds: const ['codex', 'claude-code'],
        currentTargets: known,
        rescanKnown: true,
      ),
      ['codex', 'claude-code'],
    );
  });

  test('ordering preserves unknown persisted ids and honors pins', () {
    final ordered = TargetPolicy.orderedConversationTargets(
      targets: [_target('codex'), _target('opencode')],
      persistedOrder: const ['opencode', 'missing', 'codex'],
      pinnedIds: const ['opencode'],
    );
    expect(ordered.map((target) => target.target), ['opencode', 'codex']);

    final pinnedCodex = TargetPolicy.orderedConversationTargets(
      targets: [_target('codex'), _target('opencode')],
      persistedOrder: const ['opencode', 'codex'],
      pinnedIds: const ['codex'],
    );
    expect(pinnedCodex.map((target) => target.target), ['codex', 'opencode']);

    final next = TargetPolicy.reorderedTabIds(
      visibleTargets: ordered,
      persistedOrder: const ['opencode', 'missing', 'codex'],
      oldIndex: 1,
      newIndex: 0,
    );
    expect(next, ['codex', 'opencode', 'missing']);
  });

  test('unused scan keeps a selected-agent model catalog', () {
    final selected = _cursor(
      modelCatalog: {
        'sources': ['cursor-cli'],
        'models': [
          {'name': 'composer-2.5'},
          {'name': 'auto'},
        ],
      },
    );
    final scan = _cursor(
      modelCatalog: {
        'sources': ['config'],
        'models': [
          {'name': 'stale-cursor-model'},
        ],
      },
    );
    final merged = TargetPolicy.mergeProbe(
      [selected],
      'cursor',
      scan,
      replaceModelCatalog: false,
    );
    expect(merged.single.modelCatalog['sources'], ['cursor-cli']);
    expect(
      (merged.single.modelCatalog['models'] as List).map(
        (model) => (model as Map)['name'],
      ),
      ['composer-2.5', 'auto'],
    );
  });

  test('Kilo editor history remains a fallback until CLI catalog refresh', () {
    final historyOnly = _target('kilo-code').withModelCatalog({
      'sources': ['kilo-vscode-state'],
      'models': [
        {'name': 'recent-only'},
      ],
    });
    final native = _target('kilo-code').withModelCatalog({
      'sources': ['kilo-cli'],
      'models': [
        {'name': 'kilo/kilo-auto/free'},
      ],
    });

    expect(TargetPolicy.hasSelectedAgentModelCatalog(historyOnly), isFalse);
    expect(TargetPolicy.hasSelectedAgentModelCatalog(native), isTrue);
    expect(
      TargetPolicy.hasSelectedAgentModelCatalog(
        _target('opencode').withModelCatalog({
          'sources': ['opencode-cli:models'],
        }),
      ),
      isTrue,
    );
  });

  test('Claude current model is a settled native catalog', () {
    final target = _target('claude-code').withModelCatalog({
      'sources': ['claude-current'],
      'models': [
        {'name': 'configured-current-model'},
      ],
    });

    expect(TargetPolicy.hasSelectedAgentModelCatalog(target), isTrue);
  });

  test(
    'a persisted native catalog is refreshed once in each process',
    () async {
      final persisted = _cursor(
        modelCatalog: {
          'sources': ['cursor-cli'],
          'models': [
            {'name': 'persisted'},
          ],
        },
      );
      final refreshed = _cursor(
        modelCatalog: {
          'sources': ['cursor-cli'],
          'models': [
            {'name': 'fresh'},
          ],
        },
      );
      final gateway = _Gateway(
        probes: {'cursor': persisted},
        selectedProbes: {'cursor': refreshed},
      );
      final controller = TargetController(
        gateway: gateway,
        snapshotRepository: _SnapshotRepository(),
        tabOrderRepository: _TabOrderRepository(),
        portableData: Object(),
        packagedTargetIds: const ['cursor'],
        isMobileRuntime: () => false,
        scanMobileTargets: () async => const [],
        onTargetsSettled: () {},
        loadSelectedConversation: () async {},
        shouldLoadSelectedConversation: () => false,
        onStatus: (_) {},
      );
      addTearDown(controller.dispose);
      controller.replaceTargets([persisted]);

      expect(
        await controller.ensureConversationRuntimeBinding('cursor'),
        isTrue,
      );
      await Future<void>.delayed(Duration.zero);
      while (controller.isRefreshingNativeModelCatalog('cursor')) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(gateway.catalogLookups, [true]);
      expect(
        (controller.targets.single.modelCatalog['models'] as List)
            .single['name'],
        'fresh',
      );

      expect(
        await controller.ensureConversationRuntimeBinding('cursor'),
        isTrue,
      );
      expect(gateway.catalogLookups, [true]);
    },
  );

  test(
    'opening a bound agent conversation interface refreshes its native model catalog once',
    () async {
      final incomplete = _cursor(
        modelCatalog: {
          'sources': ['config'],
          'models': [
            {'name': 'stale-cursor-model'},
          ],
        },
      );
      final complete = _cursor(
        modelCatalog: {
          'sources': ['cursor-cli'],
          'models': [
            {'name': 'auto'},
            {'name': 'composer-2.5'},
          ],
        },
      );
      final gateway = _Gateway(
        probes: {'cursor': incomplete},
        selectedProbes: {'cursor': complete},
      );
      final controller = TargetController(
        gateway: gateway,
        snapshotRepository: _SnapshotRepository(),
        tabOrderRepository: _TabOrderRepository(),
        portableData: Object(),
        packagedTargetIds: const ['cursor'],
        isMobileRuntime: () => false,
        scanMobileTargets: () async => const [],
        onTargetsSettled: () {},
        loadSelectedConversation: () async {},
        shouldLoadSelectedConversation: () => false,
        onStatus: (_) {},
      );
      addTearDown(controller.dispose);
      controller.replaceTargets([incomplete]);

      expect(
        await controller.ensureConversationRuntimeBinding('cursor'),
        isTrue,
      );
      final deadline = DateTime.now().add(const Duration(seconds: 1));
      while (!TargetPolicy.hasSelectedAgentModelCatalog(
            controller.targets.single,
          ) &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(gateway.catalogLookups, [true]);
      expect(
        controller.targets.single.modelCatalog['sources'],
        contains('cursor-cli'),
      );
      expect(
        (controller.targets.single.modelCatalog['models'] as List).length,
        2,
      );

      expect(
        await controller.ensureConversationRuntimeBinding('cursor'),
        isTrue,
      );
      expect(gateway.catalogLookups, [true]);
    },
  );

  test('conversation order keeps host installs and drops automatic VMs', () {
    final workingDirectory = ['', 'srv', 'project'].join('/');
    final ordered = TargetPolicy.orderedConversationTargets(
      targets: [
        _target('codex'),
        TargetCandidate(
          target: 'hermes',
          label: 'Hermes Agent',
          kind: 'cli',
          status: 'detected',
          configured: true,
          confidence: 1,
          binaryPath: 'hermes',
          adapterStatus: 'implemented',
          location: 'virtual-machine',
          scanSource: 'virtual-machine-orbstack',
          runtimeConnection: {
            'kind': 'ssh',
            'host': 'orb',
            'remoteExecutable': 'hermes',
            'workingDirectory': workingDirectory,
            'runtimeProtocol': 'hermes-tui-gateway',
          },
        ),
        TargetCandidate(
          target: 'openclaw',
          label: 'OpenClaw',
          kind: 'cli',
          status: 'not-detected',
          configured: false,
          confidence: 0.15,
          adapterStatus: 'implemented',
        ),
      ],
      persistedOrder: const ['hermes', 'openclaw', 'codex'],
    );
    expect(ordered.map((target) => target.target), ['codex']);
  });

  test(
    'controller probes concurrently and publishes one settled snapshot',
    () async {
      final gateway = _Gateway(
        probes: {
          'codex': _target('codex'),
          'claude-code': _target('claude-code'),
        },
        delays: const {
          'codex': Duration(milliseconds: 35),
          'claude-code': Duration(milliseconds: 2),
        },
      );
      final snapshots = _SnapshotRepository();
      final controller = TargetController(
        gateway: gateway,
        snapshotRepository: snapshots,
        tabOrderRepository: _TabOrderRepository(),
        portableData: Object(),
        packagedTargetIds: const ['codex', 'claude-code'],
        isMobileRuntime: () => false,
        scanMobileTargets: () async => const [],
        onTargetsSettled: () {},
        loadSelectedConversation: () async {},
        shouldLoadSelectedConversation: () => false,
        onStatus: (_) {},
      );
      addTearDown(controller.dispose);
      final observations = <List<String>>[];
      controller.addListener(() {
        observations.add(
          controller.targets.map((target) => target.target).toList(),
        );
      });

      await controller.scan(showProgress: false);

      expect(gateway.maxInFlight, 2);
      expect(
        controller.targets.map((target) => target.target),
        containsAll(['codex', 'claude-code']),
      );
      expect(
        observations.where((ids) => ids.isNotEmpty),
        everyElement(containsAll(['codex', 'claude-code'])),
      );
      expect(snapshots.saved, isNotEmpty);
      expect(snapshots.saveCalls, 1);
    },
  );

  test(
    'controller emits allowlisted error codes without raw exceptions',
    () async {
      final updates = <TargetStatusUpdate>[];
      final controller = TargetController(
        gateway: _Gateway(failTools: true),
        snapshotRepository: _SnapshotRepository(),
        tabOrderRepository: _TabOrderRepository(),
        portableData: Object(),
        packagedTargetIds: const [],
        isMobileRuntime: () => false,
        scanMobileTargets: () async => const [],
        onTargetsSettled: () {},
        loadSelectedConversation: () async {},
        shouldLoadSelectedConversation: () => false,
        onStatus: updates.add,
      );
      addTearDown(controller.dispose);

      await controller.inspectTarget('codex');

      expect(controller.lastErrorCode, 'target_inspect_failed');
      expect(updates.last.errorCode, 'target_inspect_failed');
      expect(updates.last.english, isNot(contains('private-runtime-detail')));
    },
  );

  test('conversation history load failure does not fail the scan', () async {
    final updates = <TargetStatusUpdate>[];
    final controller = TargetController(
      gateway: _Gateway(probes: {'codex': _target('codex')}),
      snapshotRepository: _SnapshotRepository(),
      tabOrderRepository: _TabOrderRepository(),
      portableData: Object(),
      packagedTargetIds: const ['codex'],
      isMobileRuntime: () => false,
      scanMobileTargets: () async => const [],
      onTargetsSettled: () {},
      loadSelectedConversation: () async =>
          throw StateError('native history read failed'),
      shouldLoadSelectedConversation: () => true,
      onStatus: updates.add,
    );
    addTearDown(controller.dispose);

    await controller.scan(showProgress: true);

    // The scan itself succeeded; the history read failure must not be
    // reported as a scan failure nor leave the busy flag set.
    expect(controller.lastErrorCode, isEmpty);
    expect(
      updates.map((update) => update.errorCode),
      isNot(contains('target_scan_failed')),
    );
    expect(controller.isScanning, isFalse);
    expect(
      controller.targets.map((target) => target.target),
      contains('codex'),
    );
  });

  test('slow conversation history load does not block later scans', () async {
    final gateway = _Gateway(probes: {'codex': _target('codex')});
    final loadGate = Completer<void>();
    var loadCalls = 0;
    final controller = TargetController(
      gateway: gateway,
      snapshotRepository: _SnapshotRepository(),
      tabOrderRepository: _TabOrderRepository(),
      portableData: Object(),
      packagedTargetIds: const ['codex'],
      isMobileRuntime: () => false,
      scanMobileTargets: () async => const [],
      onTargetsSettled: () {},
      loadSelectedConversation: () {
        loadCalls += 1;
        return loadGate.future;
      },
      shouldLoadSelectedConversation: () => true,
      onStatus: (_) {},
    );
    addTearDown(controller.dispose);

    final firstScan = controller.scan(showProgress: true);
    // Wait until the first scan released the refresh gate and entered the
    // history load.
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final secondScan = controller.scan(
      showProgress: true,
      forceRescanKnown: true,
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    loadGate.complete();
    await Future.wait([firstScan, secondScan]);

    expect(
      gateway.scanCounts['codex'],
      2,
      reason: 'the history load must not hold the refresh gate',
    );
    expect(loadCalls, 2);
    expect(controller.isScanning, isFalse);
  });

  test('concurrent forced scans coalesce after an active quiet scan', () async {
    final gateway = _Gateway(
      probes: {'codex': _target('codex')},
      delays: const {'codex': Duration(milliseconds: 25)},
    );
    final controller = TargetController(
      gateway: gateway,
      snapshotRepository: _SnapshotRepository(),
      tabOrderRepository: _TabOrderRepository(),
      portableData: Object(),
      packagedTargetIds: const ['codex'],
      isMobileRuntime: () => false,
      scanMobileTargets: () async => const [],
      onTargetsSettled: () {},
      loadSelectedConversation: () async {},
      shouldLoadSelectedConversation: () => false,
      onStatus: (_) {},
    );
    addTearDown(controller.dispose);

    final quietScan = controller.scan(showProgress: false);
    await Future<void>.delayed(const Duration(milliseconds: 1));
    final forcedScans = [
      for (var index = 0; index < 3; index += 1)
        controller.scan(showProgress: true, forceRescanKnown: true),
    ];
    await Future.wait([quietScan, ...forcedScans]);

    expect(gateway.scanCounts['codex'], 2);
    expect(controller.isScanning, isFalse);
  });
}

TargetCandidate _target(String id) => TargetCandidate(
  target: id,
  label: id,
  kind: 'cli',
  status: 'detected',
  configured: true,
  confidence: 1,
  adapterStatus: 'ready',
);

TargetCandidate _cursor({required Map<String, dynamic> modelCatalog}) =>
    TargetCandidate(
      target: 'cursor',
      label: 'Cursor',
      kind: 'cli',
      status: 'detected',
      configured: true,
      confidence: 1,
      binaryPath: ['', 'synthetic', 'bin', 'cursor-agent'].join('/'),
      adapterStatus: 'implemented',
      adapterCapabilities: const {'conversationDriver': 'implemented'},
      modelCatalog: modelCatalog,
    );

class _Gateway implements TargetManagementGateway {
  _Gateway({
    this.probes = const {},
    this.selectedProbes = const {},
    this.delays = const {},
    this.failTools = false,
  });

  final Map<String, TargetCandidate?> probes;
  final Map<String, TargetCandidate?> selectedProbes;
  final Map<String, Duration> delays;
  final bool failTools;
  var _inFlight = 0;
  var maxInFlight = 0;
  final Map<String, int> scanCounts = {};
  final List<bool> catalogLookups = [];

  @override
  Future<TargetCandidate?> scanOneTarget(
    String targetId, {
    bool enableAgentCliModelLookup = false,
  }) async {
    catalogLookups.add(enableAgentCliModelLookup);
    scanCounts.update(targetId, (count) => count + 1, ifAbsent: () => 1);
    _inFlight += 1;
    maxInFlight = _inFlight > maxInFlight ? _inFlight : maxInFlight;
    try {
      await Future<void>.delayed(delays[targetId] ?? Duration.zero);
      if (enableAgentCliModelLookup && selectedProbes.containsKey(targetId)) {
        return selectedProbes[targetId];
      }
      return probes[targetId];
    } finally {
      _inFlight -= 1;
    }
  }

  Never _failure() => throw StateError('private-runtime-detail');

  @override
  Future<Map<String, dynamic>> addTarget({
    required String target,
    String configPath = '',
    String binaryPath = '',
    String historyRoot = '',
    String location = 'local',
    Map<String, dynamic> runtimeConnection = const <String, dynamic>{},
  }) async => failTools ? _failure() : {'ok': true};

  @override
  Future<Map<String, dynamic>> inspectTarget(String target) async =>
      failTools ? _failure() : {'target': target};

  @override
  Future<Map<String, dynamic>> restoreSnapshot(String snapshotId) async =>
      failTools ? _failure() : {'snapshotId': snapshotId};
}

class _SnapshotRepository implements TargetSnapshotRepository {
  List<TargetCandidate> loaded = const [];
  List<TargetCandidate> saved = const [];
  var saveCalls = 0;

  @override
  Future<List<TargetCandidate>> load(Object portableData) async => loaded;

  @override
  Future<void> save(Object portableData, List<TargetCandidate> targets) async {
    saveCalls += 1;
    saved = List.unmodifiable(targets);
  }
}

class _TabOrderRepository implements TargetTabOrderRepository {
  List<String> value = const [];
  List<String> pinned = const [];
  bool customPinned = false;

  @override
  Future<List<String>> load(Object portableData) async => value;

  @override
  Future<void> save(Object portableData, List<String> order) async {
    value = List.unmodifiable(order);
  }

  @override
  Future<List<String>> loadPinned(Object portableData) async => pinned;

  @override
  Future<void> savePinned(Object portableData, List<String> next) async {
    pinned = List.unmodifiable(next);
    customPinned = true;
  }

  @override
  Future<bool> hasCustomPinnedIds(Object portableData) async => customPinned;
}
