import 'dart:async';
import 'dart:io';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/application/features/catalog_convergence/controller/catalog_convergence_controller.dart';
import 'package:licoup/src/contracts/catalog_convergence/catalog_convergence_gateway.dart';
import 'package:licoup/src/contracts/catalog_convergence/catalog_convergence_models.dart';
import 'package:licoup/src/platform/storage/portable_data_root.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/client_controller/support/fake_agent_service.dart';

void main() {
  test(
    'bootstrap reports empty configuration without inventing a service',
    () async {
      final gateway = _FakeGateway();
      final controller = CatalogConvergenceController(gateway: gateway);
      addTearDown(controller.dispose);

      await controller.bootstrap();

      expect(controller.phase, CatalogConvergencePhase.disabled);
      expect(controller.reasonCode, 'catalog_not_configured');
      expect(gateway.calls, ['status']);
    },
  );

  test(
    'concurrent invalidations share one authenticated pull per partition',
    () async {
      final gateway = _FakeGateway();
      final controller = CatalogConvergenceController(gateway: gateway);
      addTearDown(controller.dispose);
      final release = Completer<CatalogFetchedSnapshot>();
      var pulls = 0;
      final invalidation = CatalogInvalidation(
        affectedPartitions: const ['opaque-a'],
        sourceRevision: 2,
        catalogRevision: 'catalog-2',
        audienceRevision: 3,
        reasonCode: 'upstream_audiences_published',
      );

      final first = controller.handleInvalidation(
        invalidation,
        pull: (_) {
          pulls += 1;
          return release.future;
        },
      );
      final second = controller.handleInvalidation(
        invalidation,
        pull: (_) {
          pulls += 1;
          return release.future;
        },
      );
      await Future<void>.delayed(Duration.zero);
      expect(pulls, 1);
      release.complete(_snapshot);

      expect(await Future.wait([first, second]), everyElement(isTrue));
      expect(gateway.replacements, ['opaque-a']);
      expect(controller.phase, CatalogConvergencePhase.ready);
    },
  );

  test(
    'discovery observes UI revision only after an available projection',
    () async {
      final gateway = _FakeGateway()..discoveryAvailable = false;
      final controller = CatalogConvergenceController(gateway: gateway);
      addTearDown(controller.dispose);

      final blocked = await controller.discover('opaque-a');
      expect(blocked.ok, isFalse);
      expect(gateway.observed, isEmpty);

      gateway.discoveryAvailable = true;
      final available = await controller.discover('opaque-a');
      expect(available.ok, isTrue);
      expect(gateway.observed, ['opaque-a']);
    },
  );

  test(
    'disable purges every partition before projecting disabled state',
    () async {
      final gateway = _FakeGateway();
      final controller = CatalogConvergenceController(gateway: gateway);
      addTearDown(controller.dispose);

      await controller.disable();

      expect(gateway.purges, ['*']);
      expect(controller.phase, CatalogConvergencePhase.disabled);
      expect(controller.status.partitionCount, 0);
    },
  );

  test(
    'client lifecycle loads only local convergence state at startup',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lico-catalog-lifecycle-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final gateway = _FakeGateway();
      final controller = ClientController(
        portableData: PortableDataRoot(dataDirectoryOverride: directory),
        agentService: FakeAgentService(),
        catalogConvergenceGateway: gateway,
        mobileClientRuntimePlatformOverride: true,
      );
      addTearDown(controller.dispose);

      await controller.initialize();

      expect(gateway.calls, ['status']);
      expect(
        controller.catalogConvergenceController.phase,
        CatalogConvergencePhase.disabled,
      );
    },
  );
}

final _snapshot = CatalogFetchedSnapshot(
  sourceRevision: 2,
  catalogRevision: 'catalog-2',
  audienceRevision: 3,
  tools: const [
    {'name': 'upstream.synthetic', 'description': 'Synthetic'},
  ],
);

final class _FakeGateway implements CatalogConvergenceGateway {
  final calls = <String>[];
  final replacements = <String>[];
  final observed = <String>[];
  final purges = <String>[];
  bool discoveryAvailable = true;

  CatalogConvergenceStatus _status = CatalogConvergenceStatus.empty();

  @override
  Future<void> beginReconnect() async {
    calls.add('reconnect');
  }

  @override
  Future<List<String>> invalidate(CatalogInvalidation notification) async {
    calls.add('invalidate');
    return notification.affectedPartitions;
  }

  @override
  Future<CatalogDiscoveryResult> listTools(String partitionKey) async {
    calls.add('list');
    return CatalogDiscoveryResult(
      ok: discoveryAvailable,
      reasonCode: discoveryAvailable ? 'ok' : 'catalog_reconciliation_required',
      tools: discoveryAvailable ? _snapshot.tools : const [],
      sourceRevision: discoveryAvailable ? 2 : null,
      catalogRevision: discoveryAvailable ? 'catalog-2' : null,
      audienceRevision: discoveryAvailable ? 3 : null,
    );
  }

  @override
  Future<bool> observeUi(String partitionKey) async {
    observed.add(partitionKey);
    _status = const CatalogConvergenceStatus(
      partitionCount: 1,
      inFlightCount: 0,
      pendingInvalidationCount: 0,
      reconnectFence: false,
      lastKnownAudienceRevision: 3,
      uiObservedRevision: 3,
      appliedCohortCount: 1,
      pendingCohortCount: 0,
      fencedCohortCount: 0,
      disconnectedCohortCount: 0,
    );
    return true;
  }

  @override
  Future<void> purge({String partitionKey = ''}) async {
    purges.add(partitionKey.isEmpty ? '*' : partitionKey);
    _status = CatalogConvergenceStatus.empty();
  }

  @override
  Future<void> replacePartition(
    String partitionKey,
    CatalogFetchedSnapshot snapshot,
  ) async {
    replacements.add(partitionKey);
    _status = const CatalogConvergenceStatus(
      partitionCount: 1,
      inFlightCount: 0,
      pendingInvalidationCount: 0,
      reconnectFence: false,
      lastKnownAudienceRevision: 3,
      uiObservedRevision: -1,
      appliedCohortCount: 1,
      pendingCohortCount: 0,
      fencedCohortCount: 0,
      disconnectedCohortCount: 0,
    );
  }

  @override
  Future<CatalogConvergenceStatus> status() async {
    calls.add('status');
    return _status;
  }
}
