import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/platform/agents/scanned_targets_cache_store.dart';
import 'package:licoup/src/platform/mobile_relay/mobile_relay_json_store.dart';
import 'package:licoup/src/platform/native_client/agent_service.dart';
import 'package:licoup/src/platform/storage/portable_data_root.dart';

void main() {
  test('scanned targets cache round-trips visible agents only', () async {
    final workingDirectory = _guestPath(['srv', 'project']);
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
      TargetCandidate(
        target: 'openclaw',
        label: 'OpenClaw VM',
        kind: 'cli',
        status: 'configured',
        configured: true,
        confidence: 1,
        binaryPath: 'openclaw',
        adapterStatus: 'implemented',
        location: 'virtual-machine',
        runtimeConnection: {
          'kind': 'ssh',
          'host': 'vm.example',
          'remoteExecutable': 'openclaw',
          'workingDirectory': workingDirectory,
        },
      ),
    ]);

    final loaded = await store.load(portable);
    expect(loaded, hasLength(1));
    expect(loaded.single.target, 'codex');
  });

  test(
    'scanned targets cache rejects persisted VM connection metadata',
    () async {
      final workingDirectory = _guestPath(['srv', 'project']);
      final directory = await Directory.systemTemp.createTemp(
        'lico-vm-scanned-targets-cache-',
      );
      addTearDown(() async {
        if (await directory.exists()) {
          await directory.delete(recursive: true);
        }
      });
      final portable = PortableDataRoot(dataDirectoryOverride: directory);
      await const MobileRelayJsonStore().write(
        portable,
        'scanned-targets-cache.json',
        {
          'schemaVersion': 2,
          'candidates': [
            {
              'target': 'openclaw',
              'label': 'OpenClaw VM',
              'kind': 'vm-cli',
              'status': 'configured',
              'configured': true,
              'confidence': 1,
              'adapterStatus': 'implemented',
              'location': 'virtual-machine',
              'runtimeConnection': {
                'kind': 'ssh',
                'host': 'vm.example',
                'remoteExecutable': 'openclaw',
                'workingDirectory': workingDirectory,
              },
            },
          ],
        },
        lock: true,
      );

      final loaded = await const PlatformScannedTargetsCacheStore().load(
        portable,
      );
      expect(loaded, isEmpty);
    },
  );

  test(
    'scanned targets cache restores metadata without touching binary authority',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lico-stale-scanned-target-',
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
          target: 'claude-code',
          label: 'Claude Code',
          kind: 'cli',
          status: 'detected',
          configured: true,
          confidence: 1,
          binaryPath: '${directory.path}/disappeared-claude',
          adapterStatus: 'implemented',
        ),
      ]);

      final restored = await store.load(portable);
      expect(restored, hasLength(1));
      expect(restored.single.binaryPath, isNull);
      expect(restored.single.canRelayRuntime, isFalse);
    },
  );

  test('quiet scan revalidates agents restored from cache', () async {
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

    await controller.targetController.hydrateCache();
    expect(
      controller.scannedTargets.any((target) => target.target == 'codex'),
      isTrue,
    );

    await controller.scanTargets(showProgress: false, forceRescanKnown: false);

    expect(service.scannedIds.contains('codex'), isTrue);
    expect(
      service.conversationActions,
      isEmpty,
      reason:
          'cache hydration and availability scans must never write '
          'conversation memberships',
    );
    expect(service.scannedIds, isNotEmpty);
    expect(
      service.maxInFlight,
      greaterThan(1),
      reason: 'cached and unknown agents should be probed concurrently',
    );
  });

  test('reopening a cached agent refreshes its executable binding', () async {
    final directory = await Directory.systemTemp.createTemp(
      'lico-reopen-cached-target-',
    );
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });
    final portable = PortableDataRoot(dataDirectoryOverride: directory);
    const cache = PlatformScannedTargetsCacheStore();
    final runtimeTarget = TargetCandidate(
      target: 'claude-code',
      label: 'Claude Code',
      kind: 'cli',
      status: 'detected',
      configured: true,
      confidence: 1,
      binaryPath: '/synthetic/bin/claude',
      adapterStatus: 'implemented',
      adapterCapabilities: const {'conversationDriver': 'implemented'},
    );
    await cache.save(portable, [runtimeTarget]);

    final service = _SlowPerAgentService(
      results: {'claude-code': runtimeTarget},
    );
    final controller = ClientController(
      portableData: portable,
      agentService: service,
      scannedTargetsCacheStore: cache,
    );
    addTearDown(controller.dispose);

    await controller.targetController.hydrateCache();
    controller.selectedConversationAgentId = 'claude-code';
    controller.conversationSessionsByAgent = const {
      'claude-code': [
        AgentConversationSession(
          id: 'synthetic-session',
          agentId: 'claude-code',
          title: 'Synthetic session',
          createdAt: '2026-01-01T00:00:00Z',
          updatedAt: '2026-01-01T00:00:00Z',
          messages: [],
        ),
      ],
    };
    expect(controller.selectedConversationAgent?.canRelayRuntime, isFalse);

    await Future.wait([
      controller.selectConversationAgent('claude-code'),
      controller.selectConversationAgent('claude-code'),
    ]);

    expect(service.scannedIds, ['claude-code']);
    expect(controller.selectedConversationAgent?.canRelayRuntime, isTrue);

    await controller.scanTargets(showProgress: false);

    expect(
      service.scannedIds.where((id) => id == 'claude-code'),
      hasLength(1),
      reason: 'the restored binding must not be probed again by a quiet scan',
    );
  });

  test(
    'failed cached-agent rebind keeps history and the composer draft',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lico-reopen-missing-target-',
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
          target: 'claude-code',
          label: 'Claude Code',
          kind: 'cli',
          status: 'detected',
          configured: true,
          confidence: 1,
          binaryPath: '/synthetic/bin/claude',
          adapterStatus: 'implemented',
          adapterCapabilities: const {'conversationDriver': 'implemented'},
        ),
      ]);
      final service = _SlowPerAgentService();
      final controller = ClientController(
        portableData: portable,
        agentService: service,
        scannedTargetsCacheStore: cache,
      );
      addTearDown(controller.dispose);

      await controller.targetController.hydrateCache();
      controller.selectedConversationAgentId = 'claude-code';
      controller.conversationSessionsByAgent = const {
        'claude-code': [
          AgentConversationSession(
            id: 'synthetic-session',
            agentId: 'claude-code',
            title: 'Synthetic session',
            createdAt: '2026-01-01T00:00:00Z',
            updatedAt: '2026-01-01T00:00:00Z',
            messages: [],
          ),
        ],
      };
      controller.updateConversationComposerDraft('synthetic draft');

      await controller.selectConversationAgent('claude-code');

      expect(service.scannedIds, ['claude-code']);
      expect(controller.selectedConversationSessions, hasLength(1));
      expect(
        controller.selectedConversationAgent?.conversationSendGateReason,
        'native_agent_executable_not_detected',
      );
      expect(controller.conversationComposerDraft, 'synthetic draft');
    },
  );

  test(
    'force rescan publishes agents after concurrent probes settle',
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
        observed.where((ids) => ids.isNotEmpty),
        everyElement(containsAll(['codex', 'claude-code'])),
        reason: 'the sidebar should receive only complete scan projections',
      );
    },
  );
}

String _guestPath(List<String> segments) => ['', ...segments].join('/');

class _SlowPerAgentService extends AgentService {
  _SlowPerAgentService({this.results = const {}, this.delays = const {}})
    : super(runCliExecutable: null);

  final Map<String, TargetCandidate> results;
  final Map<String, Duration> delays;
  final List<String> scannedIds = <String>[];
  final List<String> conversationActions = <String>[];
  var _inFlight = 0;
  var maxInFlight = 0;

  @override
  Future<Map<String, dynamic>> runCliWithStdin(
    List<String> args,
    String stdinText,
  ) async {
    final request = Map<String, dynamic>.from(jsonDecode(stdinText) as Map);
    conversationActions.add((request['action'] as String?) ?? '');
    return {'ok': true, 'result': <String, dynamic>{}};
  }

  @override
  Future<TargetCandidate?> scanOneTarget(
    String targetId, {
    bool enableAgentCliModelLookup = false,
  }) async {
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
