import 'dart:io';

import 'package:flutter_client/src/application/features/routing/routing_module_registration_impl.dart';
import 'package:flutter_client/src/application/features/routing/routing_module_flags.dart';
import 'package:flutter_client/src/backend/features/routing/services/policy_store.dart';
import 'package:flutter_client/src/contracts/routing/routing_policy_schema.dart';
import 'package:flutter_client/src/contracts/routing/task_route_coordinator_port.dart';
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
    test('production registration hot reloads the active policy', () async {
      final policyFile = File(
        p.join(tempDir.path, defaultRoutingPolicyRelativePath),
      );
      await policyFile.create(recursive: true);
      await policyFile.writeAsString(
        File('test/fixtures/routing/valid-policy.json').readAsStringSync(),
      );
      final registration = DefaultRoutingModuleRegistration(
        rootDirectory: tempDir,
      );
      await registration.activate();
      addTearDown(registration.deactivate);
      expect(registration.coordinator, isA<TaskRouteCoordinatorPort>());
      expect(registration.activePolicy.id, 'workspace-default');

      final reloaded = registration.policyEvents
          .where((event) => event is RoutingPolicyStoreReloaded)
          .cast<RoutingPolicyStoreReloaded>()
          .first;
      await policyFile.writeAsString(
        File('test/fixtures/routing/policy-beta.json').readAsStringSync(),
      );
      await registration.policyStore!.reload();

      expect((await reloaded).document.id, 'policy-beta');
      expect(registration.activePolicy.id, 'policy-beta');
    });

    test(
      'V-005-C runtime toggle deactivates at the registration point',
      () async {
        final registration = DefaultRoutingModuleRegistration(
          rootDirectory: tempDir,
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
      },
    );

    test('V-005-D unload removes settings and state artifacts', () async {
      final registration = DefaultRoutingModuleRegistration(
        rootDirectory: tempDir,
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

      expect(
        registration.settingsView.keys.where((k) => k.startsWith('routing.')),
        isEmpty,
      );
      expect(
        await Directory(
          p.join(tempDir.path, routingModuleStateDirectory),
        ).exists(),
        isFalse,
      );
      expect(registration.policyStore, isNull);
      expect(registration.historyStore, isNull);
    });

    test('V-005-E re-enable starts clean without stale state', () async {
      final registration = DefaultRoutingModuleRegistration(
        rootDirectory: tempDir,
      );
      await registration.activate();
      registration.settingsView; // touch
      await File(
        p.join(tempDir.path, routingModuleStateDirectory, 'stale.txt'),
      ).create(recursive: true);
      await registration.unload();
      expect(
        await Directory(
          p.join(tempDir.path, routingModuleStateDirectory),
        ).exists(),
        isFalse,
      );

      await registration.enable();
      expect(registration.isReady, isTrue);
      expect(registration.activePolicy.isEmpty, isTrue);
      expect(registration.settingsView['routing.enabled'], 'true');
      expect(
        await File(
          p.join(tempDir.path, routingModuleStateDirectory, 'stale.txt'),
        ).exists(),
        isFalse,
      );
    });
  });
}
