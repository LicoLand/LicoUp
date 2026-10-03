import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/application/features/plugin_management/controller/package_center_controller.dart';
import 'package:licoup/src/application/features/plugin_management/models/package_center_catalog.dart';
import 'package:licoup/src/contracts/agent_command_runner.dart';

void main() {
  test('the four package facts render from the native package report', () {
    final catalog = PackageCenterCatalog.fromJson(
      _catalogReport([
        _package(
          packageId: 'acp-bridge',
          available: true,
          enabled: true,
          active: true,
        ),
      ]),
    );

    final facts = catalog.package('acp-bridge')!.facts;
    expect(facts.available, isTrue);
    expect(facts.installed, isTrue);
    expect(facts.enabled, isTrue);
    expect(facts.active, isTrue);
    expect(facts.notInstalled, isFalse);
  });

  test('an absent capability is not-installed on all four facts', () {
    final catalog = PackageCenterCatalog.fromJson(_catalogReport(const []));

    expect(catalog.packages, isEmpty);
    expect(catalog.package('acp-bridge'), isNull);
    expect(catalog.packageForAgent('antigravity'), isNull);
    expect(PackageCenterCatalog.empty.packages, isEmpty);

    final absent = PackageCatalogItem.absent(
      label: 'ACP Bridge',
      agentId: 'antigravity',
    );
    expect(absent.facts, PackageFactsProjection.absent);
    expect(absent.packageId, isEmpty);
    expect(absent.facts.notInstalled, isTrue);
  });

  test('a facts combination the store could not produce is refused', () {
    // An active package that is not enabled has no valid store state.
    expect(
      () => PackageCenterCatalog.fromJson(
        _catalogReport([
          _package(packageId: 'acp-bridge', enabled: false, active: true),
        ]),
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          'package_catalog_facts_inconsistent',
        ),
      ),
    );
    // The same holds for an entry whose lifecycle is not installed.
    expect(
      () => PackageCenterCatalog.fromJson(
        _catalogReport([
          _package(packageId: 'acp-bridge', lifecycle: 'staged'),
        ]),
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('an unknown schema or a refused route never reaches the projection', () {
    expect(
      () => PackageCenterCatalog.fromJson({
        'schemaVersion': 'licoup.package-lifecycle.v2',
        'packages': const [],
      }),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => PackageCenterCatalog.fromJson({
        'schemaVersion': packageLifecycleSchema,
        'isError': true,
        'reasonCode': 'package_maintenance_admission_unavailable',
      }),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          'package_maintenance_admission_unavailable',
        ),
      ),
    );
  });

  test(
    'the controller projects only what the native catalogue reported',
    () async {
      final runner = _PackageRunner(
        catalog: _catalogReport([
          _package(packageId: 'acp-bridge', available: true, enabled: true),
          _package(
            packageId: 'lico-mcp',
            available: false,
            enabled: false,
            agentId: 'kimi-code',
          ),
        ]),
      );
      final statuses = <PackageCenterStatusUpdate>[];
      final controller = PackageCenterController(
        runner: runner,
        onStatus: statuses.add,
      );
      addTearDown(controller.dispose);
      controller.useDataRoot('/tmp/synthetic-data-home');

      await controller.refresh();

      expect(runner.calls, [
        ['package', 'catalog', '/tmp/synthetic-data-home'],
      ]);
      expect(controller.loaded, isTrue);
      expect(controller.packages.map((item) => item.packageId), [
        'acp-bridge',
        'lico-mcp',
      ]);
      expect(
        controller.factsFor('acp-bridge'),
        const PackageFactsProjection(
          available: true,
          installed: true,
          enabled: true,
          active: false,
        ),
      );
      // A local import is installed without ever being available.
      expect(controller.factsFor('lico-mcp')!.available, isFalse);
      expect(controller.factsFor('lico-mcp')!.installed, isTrue);
      // A package the store does not hold is the explicit not-installed state.
      expect(controller.factsFor('missing'), isNull);
      expect(controller.factsForAgent('kimi-code').installed, isTrue);
      expect(
        controller.factsForAgent('missing-agent'),
        PackageFactsProjection.absent,
      );
    },
  );

  test('an install runs plan, confirm and apply over one archive', () async {
    final runner = _PackageRunner(
      catalog: _catalogReport(const []),
      installPlan: {
        'schemaVersion': packageLifecycleSchema,
        'isError': false,
        'plan': {'packageId': 'acp-bridge', 'version': '1.0.0'},
        'planDigest': 'sha256:plan',
        'confirmation': 'sha256:confirmation',
        'archive': '/tmp/acp-bridge.licopkg',
      },
      installedAfterApply: _package(
        packageId: 'acp-bridge',
        available: true,
        enabled: true,
      ),
    );
    final controller = PackageCenterController(
      runner: runner,
      onStatus: (_) {},
    );
    addTearDown(controller.dispose);
    controller.useDataRoot('/tmp/synthetic-data-home');

    expect(
      await controller.installFromArchive('/tmp/acp-bridge.licopkg'),
      isTrue,
    );
    expect(runner.calls, [
      [
        'package',
        'install-plan',
        '/tmp/synthetic-data-home',
        '--archive',
        '/tmp/acp-bridge.licopkg',
      ],
      [
        'package',
        'install-confirm',
        '/tmp/synthetic-data-home',
        '--archive',
        '/tmp/acp-bridge.licopkg',
        '--plan',
        'sha256:plan',
      ],
      [
        'package',
        'install-apply',
        '/tmp/synthetic-data-home',
        '--archive',
        '/tmp/acp-bridge.licopkg',
        '--confirmation',
        'sha256:confirmation',
      ],
      ['package', 'catalog', '/tmp/synthetic-data-home'],
    ]);
    expect(controller.factsFor('acp-bridge')!.installed, isTrue);
  });

  test(
    'a failed install leaves the client usable and reports the reason',
    () async {
      final runner = _PackageRunner(
        catalog: _catalogReport(const []),
        installPlan: {
          'schemaVersion': packageLifecycleSchema,
          'isError': true,
          'reasonCode': 'package_client_incompatible',
        },
      );
      final statuses = <PackageCenterStatusUpdate>[];
      final controller = PackageCenterController(
        runner: runner,
        onStatus: statuses.add,
      );
      addTearDown(controller.dispose);
      controller.useDataRoot('/tmp/synthetic-data-home');

      expect(
        await controller.installFromArchive('/tmp/acp-bridge.licopkg'),
        isFalse,
      );
      expect(controller.lastErrorCode, 'package_client_incompatible');
      expect(statuses.last.errorCode, 'package_client_incompatible');
      // Nothing was applied, and the catalogue is still readable.
      expect(runner.calls, [
        [
          'package',
          'install-plan',
          '/tmp/synthetic-data-home',
          '--archive',
          '/tmp/acp-bridge.licopkg',
        ],
      ]);
      await controller.refresh();
      expect(controller.loaded, isTrue);
      expect(controller.packages, isEmpty);
    },
  );

  test('enable and disable move only the stored preference', () async {
    final runner = _PackageRunner(
      catalog: _catalogReport([
        _package(packageId: 'acp-bridge', available: true, enabled: true),
      ]),
    );
    final controller = PackageCenterController(
      runner: runner,
      onStatus: (_) {},
    );
    addTearDown(controller.dispose);
    controller.useDataRoot('/tmp/synthetic-data-home');

    expect(
      await controller.setEnabled(
        packageId: 'acp-bridge',
        version: '1.0.0',
        enabled: false,
      ),
      isTrue,
    );
    expect(runner.calls.first, [
      'package',
      'disable',
      '/tmp/synthetic-data-home',
      'acp-bridge',
      '1.0.0',
    ]);
  });

  test('no native route is addressed before the data home resolves', () async {
    final runner = _PackageRunner(catalog: _catalogReport(const []));
    final statuses = <PackageCenterStatusUpdate>[];
    final controller = PackageCenterController(
      runner: runner,
      onStatus: statuses.add,
    );
    addTearDown(controller.dispose);

    await controller.refresh();

    expect(runner.calls, isEmpty);
    expect(controller.loaded, isFalse);
    expect(controller.lastErrorCode, 'package_data_root_unresolved');
  });
}

Map<String, dynamic> _catalogReport(List<Map<String, Object?>> packages) => {
  'schemaVersion': packageLifecycleSchema,
  'isError': false,
  'operation': 'catalog',
  'dataHomeResolved': true,
  'storeRoot': '/tmp/synthetic-data-home/packages',
  'recoveredBeforeRead': true,
  'packages': packages,
};

Map<String, Object?> _package({
  required String packageId,
  String version = '1.0.0',
  String lifecycle = 'installed',
  String source = 'official-directory',
  String capabilityKind = 'licoup-capability',
  bool available = false,
  bool enabled = true,
  bool active = false,
  String agentId = 'antigravity',
}) => {
  'packageId': packageId,
  'version': version,
  'label': packageId,
  'capabilityKind': capabilityKind,
  'lifecycle': lifecycle,
  'source': source,
  'available': available,
  'enabled': enabled,
  'active': active,
  'agentId': agentId,
  'installedAtUnixMs': 1767225600000,
};

/// A synthetic native package store: it answers the routes the package center
/// uses and records every invocation, so the tests assert the command contract
/// without a real store or a real data home.
final class _PackageRunner implements AgentCommandRunner {
  _PackageRunner({
    required this.catalog,
    this.installPlan,
    this.installedAfterApply,
  });

  final Map<String, dynamic> catalog;
  final Map<String, dynamic>? installPlan;
  final Map<String, Object?>? installedAfterApply;
  final List<List<String>> calls = [];

  @override
  Future<Map<String, dynamic>> runCli(List<String> args) async {
    calls.add(List.unmodifiable(args));
    if (args.length >= 2 && args[0] == 'package') {
      switch (args[1]) {
        case 'catalog':
          return catalog;
        case 'install-plan':
          return installPlan ??
              const {
                'isError': true,
                'reasonCode': 'package_archive_unavailable',
              };
        case 'install-confirm':
          return const {
            'schemaVersion': packageLifecycleSchema,
            'isError': false,
          };
        case 'install-apply':
          final installed = installedAfterApply;
          if (installed != null) {
            catalog['packages'] = [installed];
          }
          return const {
            'schemaVersion': packageLifecycleSchema,
            'isError': false,
          };
        case 'enable':
        case 'disable':
          return const {
            'schemaVersion': packageLifecycleSchema,
            'isError': false,
          };
      }
    }
    throw StateError('unexpected native route: ${args.join(' ')}');
  }

  @override
  Future<Map<String, dynamic>> runCliWithStdin(
    List<String> args,
    String stdinText,
  ) => runCli(args);

  @override
  Stream<Map<String, dynamic>> streamCliJsonLines(List<String> args) =>
      const Stream.empty();

  @override
  Stream<Map<String, dynamic>> streamCliJsonLinesWithStdin(
    List<String> args,
    String stdinText,
  ) => const Stream.empty();
}
