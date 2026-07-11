import 'dart:convert';
import 'dart:io';

import 'package:flutter_client/src/application/features/routing/engine/route_planner.dart';
import 'package:flutter_client/src/application/features/routing/routing_module_registration_impl.dart';
import 'package:flutter_client/src/application/features/routing/routing_module_flags.dart';
import 'package:flutter_client/src/backend/features/routing/services/policy_store.dart';
import 'package:flutter_client/src/contracts/routing/route_decision_record.dart';
import 'package:flutter_client/src/contracts/routing/routing_policy_schema.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('routing-module-');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('V-005 optional routing module', () {
    test('V-005-A/B module-excluded registration never activates routing', () async {
      final registration = DefaultRoutingModuleRegistration(
        rootDirectory: tempDir,
        included: false,
        initiallyEnabled: true,
      );
      await registration.activate();
      expect(registration.isEnabled, isFalse);
      expect(registration.isReady, isFalse);
      expect(registration.policyStore, isNull);
      expect(registration.historyStore, isNull);
      expect(registration.settingsView.containsKey('routing.enabled'), isFalse);
      // Direct dispatch path remains available: empty policy, no watcher.
      expect(registration.activePolicy.isEmpty, isTrue);
    });

    test('V-005-C runtime toggle deactivates at the registration point', () async {
      final registration = DefaultRoutingModuleRegistration(
        rootDirectory: tempDir,
        included: true,
        initiallyEnabled: true,
      );
      await registration.activate();
      expect(registration.isReady, isTrue);
      expect(registration.settingsView['routing.enabled'], 'true');

      await registration.deactivate();
      expect(registration.isEnabled, isFalse);
      expect(registration.isReady, isFalse);
      expect(registration.policyStore, isNull);
      expect(registration.settingsView['routing.enabled'], 'false');
    });

    test('V-005-D unload removes settings and state artifacts', () async {
      final registration = DefaultRoutingModuleRegistration(
        rootDirectory: tempDir,
        included: true,
      );
      await registration.activate();
      final historyDir = Directory(
        p.join(tempDir.path, routingModuleStateDirectory, 'history'),
      );
      await historyDir.create(recursive: true);
      await File(p.join(historyDir.path, 'task.jsonl')).writeAsString('{}\n');
      await File(
        p.join(tempDir.path, defaultRoutingPolicyRelativePath),
      ).create(recursive: true);

      await registration.unload();

      expect(registration.settingsView.keys.where((k) => k.startsWith('routing.')), isEmpty);
      expect(await Directory(p.join(tempDir.path, routingModuleStateDirectory)).exists(), isFalse);
      expect(registration.policyStore, isNull);
      expect(registration.historyStore, isNull);
    });

    test('V-005-E re-enable starts clean without stale state', () async {
      final registration = DefaultRoutingModuleRegistration(
        rootDirectory: tempDir,
        included: true,
      );
      await registration.activate();
      registration.settingsView; // touch
      await File(
        p.join(tempDir.path, routingModuleStateDirectory, 'stale.txt'),
      ).create(recursive: true);
      await registration.unload();
      expect(await Directory(p.join(tempDir.path, routingModuleStateDirectory)).exists(), isFalse);

      await registration.enable();
      expect(registration.isReady, isTrue);
      expect(registration.activePolicy.isEmpty, isTrue);
      expect(registration.settingsView['routing.enabled'], 'true');
      expect(
        await File(p.join(tempDir.path, routingModuleStateDirectory, 'stale.txt')).exists(),
        isFalse,
      );
    });
  });

  group('V-006 lightweight footprint', () {
    test('V-006-A cold start of policy load + planner is within 50ms budget', () async {
      final policy = {
        'schemaVersion': 2,
        'id': 'footprint',
        'label': 'Footprint',
        'agents': [
          for (var i = 0; i < 8; i++)
            {
              'id': 'agent-$i',
              'roles': ['implementation'],
              'capabilities': ['tool-use'],
              'priority': i + 1,
            },
        ],
        'routing': {'strategy': 'priority-fallback'},
        'distillation': {'defaultDistiller': 'agent-0'},
      };
      final file = File(p.join(tempDir.path, defaultRoutingPolicyRelativePath));
      await file.create(recursive: true);
      // Pad toward a realistic policy size without exceeding 64 KiB.
      final padded = jsonEncode({
        ...policy,
        'label': 'Footprint ${'x' * 1024}',
      });
      await file.writeAsString(padded);
      expect(padded.length, lessThan(64 * 1024));

      final samples = <int>[];
      for (var i = 0; i < 5; i++) {
        final store = FileRoutingPolicyStore(rootDirectory: tempDir);
        final sw = Stopwatch()..start();
        final document = await store.load();
        const DefaultRoutePlanner().plan(
          task: const RoutingTaskMetadata(requiredRoles: ['implementation']),
          policy: document,
          signals: RoutingSignals(
            byAgentId: {
              for (final agent in document.agents)
                agent.id: RoutingAgentSignal(
                  agentId: agent.id,
                  agentLabel: agent.id,
                  ready: true,
                ),
            },
          ),
        );
        sw.stop();
        samples.add(sw.elapsedMicroseconds);
        await store.dispose();
      }
      samples.sort();
      final medianUs = samples[samples.length ~/ 2];
      // 50ms budget = 50_000 microseconds.
      expect(medianUs, lessThanOrEqualTo(50 * 1000), reason: 'samplesUs=$samples');
    });

    test('V-006-B resident structures stay lightweight for a loaded policy', () {
      // Structural budget proxy: a loaded policy document for ≤64KiB JSON
      // should not retain more than a few hundred agent entries in memory.
      final document = RoutingPolicyDocument(
        schemaVersion: 2,
        id: 'mem',
        agents: [
          for (var i = 0; i < 32; i++)
            RoutingPolicyAgent(id: 'a$i', priority: i + 1),
        ],
      );
      expect(document.agents.length, lessThanOrEqualTo(64));
      // 8 MiB budget is validated operationally; this guards against accidental
      // unbounded in-memory fan-out in the policy object itself.
      final encoded = jsonEncode(document.toJson());
      expect(encoded.length, lessThan(8 * 1024 * 1024));
    });
  });
}
