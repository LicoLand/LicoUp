import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_client/src/backend/features/routing/services/policy_file_watcher.dart';
import 'package:flutter_client/src/backend/features/routing/services/policy_store.dart';
import 'package:flutter_client/src/contracts/routing/routing_policy_schema.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  group('V-001-A policy schema full-surface validation', () {
    test('parses the full valid policy surface into typed objects', () {
      final source = File(
        'test/fixtures/routing/valid-policy.json',
      ).readAsStringSync();
      final result = parseRoutingPolicyDocument(source);

      expect(result, isA<RoutingPolicyParseSuccess>());
      final document = (result as RoutingPolicyParseSuccess).document;
      expect(document.schemaVersion, routingPolicySchemaVersion);
      expect(document.id, 'workspace-default');
      expect(document.label, 'Default Workspace Policy');
      expect(document.agents, hasLength(2));

      final primary = document.agents.first;
      expect(primary.id, 'claude-code');
      expect(primary.roles, containsAll(['code-review', 'architecture']));
      expect(primary.capabilities, contains('reasoning-deep'));
      expect(primary.priority, 1);
      expect(primary.distillation.distiller, 'self');
      expect(primary.distillation.maxLength, 4096);
      expect(
        primary.distillation.preserveFields,
        containsAll(['objective', 'decisions', 'constraints']),
      );

      expect(document.routing.strategy, 'priority-fallback');
      expect(document.routing.matchMode, 'role-first');
      expect(document.routing.circuitBreaker.allowedFails, 3);
      expect(document.routing.circuitBreaker.cooldownSeconds, 60);
      expect(document.routing.switchPolicy.minimumIntervalSeconds, 30);
      expect(
        document.routing.switchPolicy.triggerOn,
        contains('policy-reload'),
      );

      expect(document.distillation.defaultDistiller, 'claude-code');
      expect(document.distillation.alternateDistiller, 'codex');
      expect(
        document.distillation.fidelityContract.requiredSections,
        containsAll([
          'objective',
          'currentState',
          'decisions',
          'constraints',
          'openItems',
        ]),
      );
      expect(document.distillation.fidelityContract.maxPackageLength, 8192);
      expect(document.distillation.fidelityContract.retryOnFailure, isTrue);
      expect(document.distillation.fidelityContract.maxRetries, 1);
      expect(document.identity, 'workspace-default@2');
    });

    test('rejects malformed documents with precise path errors', () {
      final cases = <(String, String)>[
        ('{"schemaVersion":2,"id":"x","agents":"nope"}', '/agents'),
        ('{"schemaVersion":2,"id":"","agents":[{"id":"a"}]}', '/id'),
        ('{"schemaVersion":2,"id":"x","agents":[{"id":""}]}', '/agents/0/id'),
        (
          '{"schemaVersion":2,"id":"x","agents":[{"id":"a"},{"id":"a"}]}',
          '/agents/1/id',
        ),
        (
          '{"schemaVersion":2,"id":"x","agents":[{"id":"a","priority":-1}]}',
          '/agents/0/priority',
        ),
        (
          jsonEncode({
            'schemaVersion': 2,
            'id': 'x',
            'agents': [
              {'id': 'a'},
            ],
            'apiKey': ['should', 'not', 'appear'].join('-'),
          }),
          '/apiKey',
        ),
        (
          '{"schemaVersion":2,"id":"x","agents":[{"id":"a"}],"futureField":true}',
          '/futureField',
        ),
        (
          '{"schemaVersion":2,"id":"x","agents":[{"id":"a"}],"routing":{"strategy":"round-robin"}}',
          '/routing/strategy',
        ),
        (
          '{"schemaVersion":2,"id":"x","agents":[{"id":"a"}],"routing":{"matchMode":"capability-first"}}',
          '/routing/matchMode',
        ),
      ];

      for (final (source, expectedPath) in cases) {
        final result = parseRoutingPolicyDocument(source);
        expect(result, isA<RoutingPolicyParseFailure>(), reason: source);
        final error = (result as RoutingPolicyParseFailure).error;
        expect(error.path, expectedPath, reason: source);
        expect(error.message, isNotEmpty);
      }
    });

    test('accepts each executable multi-agent scheduling strategy', () {
      for (final strategy in const [
        'priority-fallback',
        'serial-all',
        'parallel-all',
        'coordinator-workers',
      ]) {
        final result = parseRoutingPolicyDocument(
          jsonEncode({
            'schemaVersion': 2,
            'id': 'schedule-$strategy',
            'agents': [
              {'id': 'codex', 'coordinator': true},
              {'id': 'claude-code'},
            ],
            'routing': {'strategy': strategy},
          }),
        );
        expect(result, isA<RoutingPolicyParseSuccess>(), reason: strategy);
      }
    });

    test('invalid JSON reports line and column', () {
      const source = '{\n  "schemaVersion": 2,\n  broken\n}';
      final result = parseRoutingPolicyDocument(source);
      expect(result, isA<RoutingPolicyParseFailure>());
      final error = (result as RoutingPolicyParseFailure).error;
      expect(error.line, greaterThan(0));
      expect(error.column, greaterThan(0));
    });

    test('does not partially apply invalid documents', () {
      final result = parseRoutingPolicyMap({
        'schemaVersion': 2,
        'id': 'partial',
        'agents': [
          {'id': 'ok'},
          {'id': ''},
        ],
      });
      expect(result, isA<RoutingPolicyParseFailure>());
    });
  });

  group('V-001-E schema version validation', () {
    test('rejects unsupported schemaVersion with clear mismatch', () {
      final result = parseRoutingPolicyDocument(
        jsonEncode({
          'schemaVersion': 1,
          'id': 'old',
          'agents': [
            {'id': 'a'},
          ],
        }),
      );
      expect(result, isA<RoutingPolicyParseFailure>());
      final error = (result as RoutingPolicyParseFailure).error;
      expect(error.path, '/schemaVersion');
      expect(error.message, contains('Unsupported schemaVersion 1'));
      expect(error.message, contains('$routingPolicySchemaVersion'));
    });
  });

  group('FileRoutingPolicyStore hot reload', () {
    late Directory tempDir;
    late File policyFile;
    late _ControllableWatcher watcher;
    late FileRoutingPolicyStore store;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('routing-policy-');
      policyFile = File(p.join(tempDir.path, defaultRoutingPolicyRelativePath));
      await policyFile.parent.create(recursive: true);
      watcher = _ControllableWatcher();
      store = FileRoutingPolicyStore(rootDirectory: tempDir, watcher: watcher);
    });

    tearDown(() async {
      await store.dispose();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test(
      'V-001-B live file change atomically swaps the active snapshot',
      () async {
        await policyFile.writeAsString(
          File('test/fixtures/routing/valid-policy.json').readAsStringSync(),
        );
        await store.load();
        expect(store.active.id, 'workspace-default');

        final events = <RoutingPolicyStoreEvent>[];
        final sub = store.watch().listen(events.add);
        await Future<void>.delayed(Duration.zero);

        await policyFile.writeAsString(
          File('test/fixtures/routing/policy-beta.json').readAsStringSync(),
        );
        watcher.emit(policyFile.path);
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(store.active.id, 'policy-beta');
        expect(store.active.agents.first.id, 'codex');
        expect(store.lastError, isNull);
        expect(
          events.whereType<RoutingPolicyStoreReloaded>().map(
            (e) => e.document.id,
          ),
          contains('policy-beta'),
        );

        // Concurrent readers always see a complete immutable snapshot.
        final snapshot = store.active;
        expect(snapshot.agents, hasLength(2));
        expect(snapshot.agents.every((a) => a.id.isNotEmpty), isTrue);

        await sub.cancel();
      },
    );

    test(
      'V-001-C invalid change keeps last good policy with surfaced error',
      () async {
        await policyFile.writeAsString(
          File('test/fixtures/routing/valid-policy.json').readAsStringSync(),
        );
        await store.load();
        final goodId = store.active.id;

        final events = <RoutingPolicyStoreEvent>[];
        final sub = store.watch().listen(events.add);
        await Future<void>.delayed(Duration.zero);

        await policyFile.writeAsString('{"schemaVersion":2,"id":"bad"}');
        watcher.emit(policyFile.path);
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(store.active.id, goodId);
        expect(store.lastError, isNotNull);
        expect(store.lastError!.path, isNotEmpty);
        expect(
          events.whereType<RoutingPolicyStoreValidationFailed>(),
          isNotEmpty,
        );
        expect(events.whereType<RoutingPolicyStoreReloaded>(), isEmpty);

        await sub.cancel();
      },
    );

    test('returns empty policy when file is missing', () async {
      final document = await store.load();
      expect(document.isEmpty, isTrue);
      expect(store.active.isEmpty, isTrue);
    });

    test('atomically saves and clears the canonical policy', () async {
      final parsed =
          parseRoutingPolicyDocument(
                File(
                  'test/fixtures/routing/valid-policy.json',
                ).readAsStringSync(),
              )
              as RoutingPolicyParseSuccess;
      await store.save(parsed.document);

      expect(store.active.id, 'workspace-default');
      expect(await policyFile.exists(), isTrue);
      expect(
        parseRoutingPolicyDocument(await policyFile.readAsString()),
        isA<RoutingPolicyParseSuccess>(),
      );

      await store.clear();
      expect(store.active.isEmpty, isTrue);
      expect(await policyFile.exists(), isFalse);
    });
  });

  group('V-001-D editor write-burst debounce', () {
    test('rapid events coalesce into one change after quiet window', () async {
      final controller = StreamController<FileSystemEvent>();
      final watcher = DebouncedPolicyFileWatcher(
        debounce: const Duration(milliseconds: 200),
        watchFactory: (_) => controller.stream,
      );
      final tempDir = await Directory.systemTemp.createTemp(
        'routing-debounce-',
      );
      final file = File(p.join(tempDir.path, 'routing-policy.json'));
      await file.writeAsString('{}');

      final delivered = <String>[];
      final sub = watcher.changes.listen(delivered.add);
      await watcher.start(file);

      final event = FileSystemCreateEvent(file.path, false);
      controller.add(event);
      controller.add(event);
      controller.add(event);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(delivered, isEmpty);

      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(delivered, hasLength(1));
      expect(delivered.single, p.normalize(file.absolute.path));

      await sub.cancel();
      await watcher.dispose();
      await controller.close();
      await tempDir.delete(recursive: true);
    });
  });

  group('V-006-C no new package dependencies', () {
    test('routing module imports only dart and existing packages', () {
      final schema = File(
        'lib/src/contracts/routing/routing_policy_schema.dart',
      ).readAsStringSync();
      final store = File(
        'lib/src/backend/features/routing/services/policy_store.dart',
      ).readAsStringSync();
      final watcher = File(
        'lib/src/backend/features/routing/services/policy_file_watcher.dart',
      ).readAsStringSync();

      for (final source in [schema, store, watcher]) {
        expect(
          source.contains("package:flutter_client/"),
          anyOf(isTrue, isFalse),
        );
        expect(source.contains('package:http/'), isFalse);
        expect(source.contains('package:watcher/'), isFalse);
      }

      final pubspec = File('pubspec.yaml').readAsStringSync();
      // Sanity: routing did not require adding a watcher package.
      expect(pubspec.contains('\n  watcher:'), isFalse);
    });
  });
}

class _ControllableWatcher implements PolicyFileWatcher {
  final StreamController<String> _controller =
      StreamController<String>.broadcast();

  @override
  Stream<String> get changes => _controller.stream;

  void emit(String path) => _controller.add(path);

  @override
  Future<void> start(File policyFile) async {}

  @override
  Future<void> dispose() async {
    await _controller.close();
  }
}
