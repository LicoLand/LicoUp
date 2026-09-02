import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/application/features/agents/adaptive_flywheel/adaptive_flywheel_target_catalog.dart';
import 'package:licoup/src/application/features/targets/controller/target_controller.dart';
import 'package:licoup/src/application/features/targets/controller/target_scan_coordinator.dart';
import 'package:licoup/src/application/features/targets/policy/target_policy.dart';
import 'package:licoup/src/application/features/targets/policy/target_scan_reducer.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/contracts/target_management.dart';

void main() {
  test(
    'equivalent target scan requests share one in-flight execution',
    () async {
      final gateway = _ControlledGateway();
      final coordinator = TargetScanCoordinator(gateway);

      final first = coordinator.scan(
        TargetScanRequest(targetIds: const ['codex', 'claude-code']),
      );
      final joined = coordinator.scan(
        TargetScanRequest(targetIds: const [' claude-code ', 'codex', 'codex']),
      );

      expect(identical(first, joined), isTrue);
      expect(gateway.calls, hasLength(1));
      gateway.calls.single.complete(
        TargetScanBatch([_slot('codex'), _slot('claude-code')]),
      );
      await Future.wait([first, joined]);

      final next = coordinator.scan(
        TargetScanRequest(targetIds: const ['codex', 'claude-code']),
      );
      expect(gateway.calls, hasLength(2));
      gateway.calls.last.complete(const TargetScanBatch([]));
      await next;
    },
  );

  test(
    'different target scan requests remain independently concurrent',
    () async {
      final gateway = _ControlledGateway();
      final coordinator = TargetScanCoordinator(gateway);

      final discovery = coordinator.scan(
        TargetScanRequest(targetIds: const ['codex']),
      );
      final catalog = coordinator.scan(
        TargetScanRequest(
          targetIds: const ['codex'],
          enableAgentCliModelLookup: true,
        ),
      );
      final otherTarget = coordinator.scan(
        TargetScanRequest(targetIds: const ['claude-code']),
      );

      expect(gateway.calls, hasLength(3));
      expect(gateway.calls[0].enableAgentCliModelLookup, isFalse);
      expect(gateway.calls[1].enableAgentCliModelLookup, isTrue);
      for (final call in gateway.calls) {
        call.complete(const TargetScanBatch([]));
      }
      await Future.wait([discovery, catalog, otherTarget]);
    },
  );

  test('scan reducer preserves agents absent from a partial response', () {
    final codex = _target('codex').withModelCatalog({
      'sources': ['config'],
      'models': [
        {'name': 'stale'},
      ],
    });
    final claude = _target('claude-code');
    final refreshedCodex = _target('codex').withModelCatalog({
      'sources': ['codex-app-server'],
      'models': [
        {'name': 'gpt-5'},
      ],
    });

    final reduction = TargetScanReducer.reduce(
      currentTargets: [codex, claude],
      requestedTargetIds: const ['codex', 'claude-code', 'cursor'],
      batch: TargetScanBatch([
        TargetScanSlot(targetId: 'codex', candidate: refreshedCodex),
        const TargetScanSlot(targetId: 'cursor', failed: true),
      ]),
      replaceModelCatalog: true,
    );

    expect(reduction.targets.map((target) => target.target), [
      'codex',
      'claude-code',
    ]);
    expect(reduction.targets.first.modelCatalog['sources'], [
      'codex-app-server',
    ]);
    expect(reduction.failedTargetIds, ['claude-code', 'cursor']);
    expect(reduction.successfulSlots.single.targetId, 'codex');
    expect(
      TargetPolicy.orderedConversationTargets(
        targets: reduction.targets,
        persistedOrder: const [],
      ).map((target) => target.target),
      ['codex', 'claude-code'],
      reason: 'the Messaging sidebar must retain the complete target list',
    );
    expect(
      agentOrchestrationCommanderTargets(
        reduction.targets,
      ).map((target) => target.target),
      ['claude-code', 'codex'],
      reason: 'Adaptive Flywheel must consume the same complete projection',
    );
  });

  test('only a successful empty slot removes its own target', () {
    final reduction = TargetScanReducer.reduce(
      currentTargets: [_target('codex'), _target('claude-code')],
      requestedTargetIds: const ['codex', 'claude-code'],
      batch: const TargetScanBatch([
        TargetScanSlot(targetId: 'codex'),
        TargetScanSlot(targetId: 'claude-code', failed: true),
      ]),
      replaceModelCatalog: false,
    );

    expect(reduction.targets.map((target) => target.target), ['claude-code']);
    expect(reduction.failedTargetIds, ['claude-code']);
  });

  test(
    'overlapping discovery and catalog scans publish one complete projection',
    () async {
      final gateway = _ControlledGateway();
      final controller = TargetController(
        gateway: gateway,
        snapshotRepository: _SnapshotRepository(),
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

      final discovery = controller.scan(
        showProgress: false,
        forceRescanKnown: true,
      );
      await Future<void>.delayed(Duration.zero);
      final catalog = controller.refreshAgentModelCatalogs(const ['codex']);
      expect(gateway.calls, hasLength(2));

      gateway.calls[1].complete(
        TargetScanBatch([
          TargetScanSlot(
            targetId: 'codex',
            candidate: _target('codex').withModelCatalog({
              'sources': ['codex-app-server'],
              'models': [
                {'name': 'gpt-5'},
              ],
            }),
          ),
        ]),
      );
      await catalog;
      gateway.calls[0].complete(
        TargetScanBatch([_slot('codex'), _slot('claude-code')]),
      );
      await discovery;

      expect(controller.targets.map((target) => target.target), [
        'codex',
        'claude-code',
      ]);
      expect(controller.targets.first.modelCatalog['sources'], [
        'codex-app-server',
      ]);
      expect(
        controller
            .orderedConversationTargets(controller.targets)
            .map((target) => target.target),
        ['codex', 'claude-code'],
      );
      expect(
        agentOrchestrationCommanderTargets(
          controller.targets,
        ).map((target) => target.target),
        ['claude-code', 'codex'],
      );
    },
  );
}

TargetScanSlot _slot(String targetId) =>
    TargetScanSlot(targetId: targetId, candidate: _target(targetId));

TargetCandidate _target(String targetId) => TargetCandidate(
  target: targetId,
  label: targetId,
  kind: 'cli',
  status: 'detected',
  configured: true,
  confidence: 1,
  binaryPath: '/synthetic/bin/$targetId',
  adapterStatus: 'implemented',
  adapterCapabilities: const {'conversationDriver': 'implemented'},
);

final class _ControlledGateway implements TargetManagementGateway {
  final List<_ScanCall> calls = [];

  @override
  Future<TargetScanBatch> scanTargetsBatch(
    List<String> targetIds, {
    bool enableAgentCliModelLookup = false,
  }) {
    final call = _ScanCall(
      targetIds: List.unmodifiable(targetIds),
      enableAgentCliModelLookup: enableAgentCliModelLookup,
    );
    calls.add(call);
    return call.future;
  }

  @override
  Future<Map<String, dynamic>> addTarget({
    required String target,
    String configPath = '',
    String binaryPath = '',
    String historyRoot = '',
    String location = 'local',
    Map<String, dynamic> runtimeConnection = const <String, dynamic>{},
  }) => throw UnimplementedError();

  @override
  Future<Map<String, dynamic>> inspectTarget(String target) =>
      throw UnimplementedError();

  @override
  Future<Map<String, dynamic>> restoreSnapshot(String snapshotId) =>
      throw UnimplementedError();
}

final class _ScanCall {
  _ScanCall({required this.targetIds, required this.enableAgentCliModelLookup});

  final List<String> targetIds;
  final bool enableAgentCliModelLookup;
  final Completer<TargetScanBatch> _completer = Completer<TargetScanBatch>();

  Future<TargetScanBatch> get future => _completer.future;

  void complete(TargetScanBatch batch) => _completer.complete(batch);
}

final class _SnapshotRepository implements TargetSnapshotRepository {
  @override
  Future<List<TargetCandidate>> load(Object portableData) async => const [];

  @override
  Future<void> save(Object portableData, List<TargetCandidate> targets) async {}
}

final class _TabOrderRepository implements TargetTabOrderRepository {
  @override
  Future<bool> hasCustomPinnedIds(Object portableData) async => false;

  @override
  Future<List<String>> load(Object portableData) async => const [];

  @override
  Future<List<String>> loadPinned(Object portableData) async => const [];

  @override
  Future<void> save(Object portableData, List<String> order) async {}

  @override
  Future<void> savePinned(Object portableData, List<String> pinned) async {}
}
