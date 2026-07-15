import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_client/src/application/controller/client_controller.dart';
import 'package:flutter_client/src/platform/agents/scanned_targets_cache_store.dart';
import 'package:flutter_client/src/platform/native_client/agent_service.dart';
import 'package:flutter_client/src/platform/storage/portable_data_root.dart';

void main() {
  test('scanned targets cache round-trips visible agents only', () async {
    final directory = await Directory.systemTemp.createTemp(
      'lico-scanned-targets-cache-',
    );
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });
    final portable = PortableDataRoot(dataDirectoryOverride: directory);
    const store = PlatformScannedTargetsCacheStore();
    await store.save(portable, [
      TargetCandidate(
        target: 'codex',
        label: 'Codex',
        kind: 'cli',
        status: 'detected',
        configured: true,
        confidence: 1,
        adapterStatus: 'implemented',
      ),
      TargetCandidate(
        target: 'missing',
        label: 'Missing',
        kind: 'cli',
        status: 'not-detected',
        configured: false,
        confidence: 0,
        adapterStatus: 'unsupported',
      ),
    ]);

    final loaded = await store.load(portable);
    expect(loaded, hasLength(1));
    expect(loaded.single.target, 'codex');
  });

  test(
    'scanTargets hydrates cache then probes only unknown agents quietly',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lico-incremental-scan-',
      );
      addTearDown(() async {
        if (await directory.exists()) {
          await directory.delete(recursive: true);
        }
      });
      final portable = PortableDataRoot(dataDirectoryOverride: directory);
      const cache = PlatformScannedTargetsCacheStore();
      await cache.save(portable, [
        TargetCandidate(
          target: 'codex',
          label: 'Codex',
          kind: 'cli',
          status: 'detected',
          configured: true,
          confidence: 1,
          adapterStatus: 'implemented',
        ),
      ]);

      final service = _SlowPerAgentService();
      final controller = ClientController(
        portableData: portable,
        agentService: service,
        scannedTargetsCacheStore: cache,
      );
      addTearDown(controller.dispose);

      controller.scannedTargets = await cache.load(portable);
      expect(
        controller.scannedTargets.any((target) => target.target == 'codex'),
        isTrue,
      );

      await controller.scanTargets(
        showProgress: false,
        forceRescanKnown: false,
      );

      // Cached agent is not re-probed on quiet scan; only unknowns are.
      expect(service.scannedIds.contains('codex'), isFalse);
      expect(service.scannedIds, isNotEmpty);
      expect(
        service.maxInFlight,
        greaterThan(1),
        reason: 'unknown agents should be probed concurrently',
      );
    },
  );

  test(
    'force rescan upserts agents as each concurrent probe returns',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lico-incremental-force-',
      );
      addTearDown(() async {
        if (await directory.exists()) {
          await directory.delete(recursive: true);
        }
      });
      final portable = PortableDataRoot(dataDirectoryOverride: directory);
      final service = _SlowPerAgentService(
        results: {
          'codex': TargetCandidate(
            target: 'codex',
            label: 'Codex',
            kind: 'cli',
            status: 'detected',
            configured: true,
            confidence: 1,
            adapterStatus: 'implemented',
          ),
          'claude-code': TargetCandidate(
            target: 'claude-code',
            label: 'Claude Code',
            kind: 'cli',
            status: 'detected',
            configured: true,
            confidence: 1,
            adapterStatus: 'implemented',
          ),
        },
        delays: const {
          'codex': Duration(milliseconds: 40),
          'claude-code': Duration(milliseconds: 5),
        },
      );
      final controller = ClientController(
        portableData: portable,
        agentService: service,
      );
      addTearDown(controller.dispose);

      final observed = <List<String>>[];
      controller.addListener(() {
        observed.add(
          controller.scannedTargets.map((target) => target.target).toList()
            ..sort(),
        );
      });

      await controller.scanTargets(showProgress: true, forceRescanKnown: true);

      expect(
        controller.scannedTargets.map((t) => t.target),
        containsAll(['codex', 'claude-code']),
      );
      expect(
        observed.any(
          (ids) => ids.contains('claude-code') && !ids.contains('codex'),
        ),
        isTrue,
        reason: 'faster probe should appear in the sidebar before slower ones',
      );
    },
  );
}

class _SlowPerAgentService extends AgentService {
  _SlowPerAgentService({this.results = const {}, this.delays = const {}})
    : super(runCliExecutable: null);

  final Map<String, TargetCandidate> results;
  final Map<String, Duration> delays;
  final List<String> scannedIds = <String>[];
  var _inFlight = 0;
  var maxInFlight = 0;

  @override
  Future<TargetCandidate?> scanOneTarget(String targetId) async {
    _inFlight += 1;
    if (_inFlight > maxInFlight) {
      maxInFlight = _inFlight;
    }
    scannedIds.add(targetId);
    try {
      await Future<void>.delayed(
        delays[targetId] ?? const Duration(milliseconds: 15),
      );
      return results[targetId];
    } finally {
      _inFlight -= 1;
    }
  }

  @override
  Future<List<TargetCandidate>> scanTargets() async {
    return results.values.toList(growable: false);
  }
}
