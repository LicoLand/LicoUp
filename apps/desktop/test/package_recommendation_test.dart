import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/application/features/plugin_management/controller/package_recommendation_controller.dart';
import 'package:licoup/src/application/features/plugin_management/models/adapter_plugin_catalog.dart';
import 'package:licoup/src/application/features/plugin_management/models/package_center_catalog.dart';
import 'package:licoup/src/application/features/plugin_management/models/package_first_launch_record.dart';
import 'package:licoup/src/composition/features/semantic_feature_channel.dart';
import 'package:licoup/src/frontend/features/plugin_management/ui/package_recommendation_sheet_host.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/plugin_management/plugin_management_binding.dart';
import 'package:licoup/src/presentation/plugin_management/plugin_management_effect.dart';
import 'package:licoup/src/presentation/plugin_management/plugin_management_intent.dart';
import 'package:licoup/src/presentation/plugin_management/plugin_management_projection.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';

import 'fixtures/plugin_management_presentation_fixture.dart';

void main() {
  test(
    'first launch records its marker before the scan and offers once',
    () async {
      final store = MemoryPackageFirstLaunchStore();
      final installer = _FakePackageInstallSource();
      final controller = PackageRecommendationController(
        installer: installer,
        store: store,
      );
      addTearDown(controller.dispose);

      final outcome = await controller.runFirstLaunch(
        adapters: _adapters([
          _adapter(
            agentId: 'antigravity',
            plugins: [_plugin(id: 'acp-bridge', label: 'ACP Bridge')],
          ),
        ]),
      );

      expect(outcome.markerRecorded, isTrue);
      expect(outcome.offered, isTrue);
      expect((await store.load()).firstLaunchCompleted, isTrue);
      expect(
        controller.pending!.recommendations.single.packageId,
        'acp-bridge',
      );

      // A second launch never re-offers the same packages.
      final second = await controller.runFirstLaunch(
        adapters: _adapters([
          _adapter(
            agentId: 'antigravity',
            plugins: [_plugin(id: 'acp-bridge', label: 'ACP Bridge')],
          ),
        ]),
      );
      expect(second.offered, isFalse);
      expect(second.markerRecorded, isFalse);
      expect(controller.pending, isNull);
    },
  );

  test(
    'the accepted set installs sequentially and contains a failure',
    () async {
      final store = MemoryPackageFirstLaunchStore();
      // The second install is refused; the first one must not be undone and
      // the third one must still run.
      final installer = _FakePackageInstallSource(failingCalls: {2});
      final controller = PackageRecommendationController(
        installer: installer,
        store: store,
      );
      addTearDown(controller.dispose);

      await controller.runFirstLaunch(
        adapters: _adapters([
          _adapter(
            agentId: 'antigravity',
            plugins: [
              _plugin(id: 'acp-bridge', label: 'ACP Bridge'),
              _plugin(id: 'lico-mcp', label: 'LicoUp MCP'),
              _plugin(id: 'lico-new', label: 'LicoUp New'),
            ],
          ),
        ]),
      );

      final results = await controller.resolveOffer(accepted: true);

      expect(installer.archives, hasLength(3));
      expect(results.map((result) => result.packageId), [
        'acp-bridge',
        'lico-mcp',
        'lico-new',
      ]);
      expect(results.map((result) => result.installed), [true, false, true]);
      expect(results[1].reasonCode, 'package_recommendation_install_failed');
      expect(controller.outcome.confirmed, isTrue);
      expect(controller.outcome.installed, 2);
      expect(controller.outcome.failed, 1);
    },
  );

  test(
    'a decline records every offered package and is never re-offered',
    () async {
      final store = MemoryPackageFirstLaunchStore();
      final installer = _FakePackageInstallSource();
      final controller = PackageRecommendationController(
        installer: installer,
        store: store,
      );
      addTearDown(controller.dispose);

      await controller.runFirstLaunch(
        adapters: _adapters([
          _adapter(
            agentId: 'antigravity',
            plugins: [_plugin(id: 'acp-bridge', label: 'ACP Bridge')],
          ),
        ]),
      );
      final results = await controller.resolveOffer(accepted: false);

      expect(installer.archives, isEmpty);
      expect(results.single.reasonCode, 'package_recommendation_declined');
      expect(controller.declined('acp-bridge'), isTrue);
      expect((await store.load()).declined('acp-bridge'), isTrue);
      expect(controller.outcome.declined, 1);
    },
  );

  test('an install failure never leaves the flow thrown', () async {
    final store = MemoryPackageFirstLaunchStore();
    final controller = PackageRecommendationController(
      installer: _ThrowingInstallSource(),
      store: store,
    );
    addTearDown(controller.dispose);

    await controller.runFirstLaunch(
      adapters: _adapters([
        _adapter(
          agentId: 'antigravity',
          plugins: [_plugin(id: 'acp-bridge', label: 'ACP Bridge')],
        ),
      ]),
    );

    final results = await controller.resolveOffer(accepted: true);
    expect(results.single.installed, isFalse);
    expect(controller.outcome.installed, 0);
    expect(controller.outcome.failed, 1);
  });

  test('already installed and declined capabilities are not offered', () async {
    final store = MemoryPackageFirstLaunchStore(
      const PackageFirstLaunchRecord(
        firstLaunchCompleted: true,
        declines: {'lico-mcp': 'declined-earlier'},
      ),
    );
    final controller = PackageRecommendationController(
      installer: _FakePackageInstallSource(),
      store: store,
    );
    addTearDown(controller.dispose);

    // The durable decision is read before the first-use check runs.
    await controller.load();
    final offer = controller.offerOnFirstUse(
      availability: PackageRecommendationController.availableCapabilities(
        _adapters([
          _adapter(
            agentId: 'antigravity',
            plugins: [
              _plugin(id: 'acp-bridge', label: 'ACP Bridge'),
              _plugin(id: 'lico-mcp', label: 'LicoUp MCP'),
              _plugin(id: 'lico-new', label: 'LicoUp New'),
            ],
          ),
        ]),
      ),
      catalog: PackageCenterCatalog.fromJson({
        'schemaVersion': packageLifecycleSchema,
        'isError': false,
        'packages': [
          _nativePackage(
            packageId: 'acp-bridge',
            available: true,
            enabled: true,
            active: true,
          ),
        ],
      }),
    );

    // Neither the installed capability nor a package the user already declined
    // is offered again.
    expect(offer!.recommendations.single.packageId, 'lico-new');
    expect(offer.firstLaunch, isFalse);
    expect(controller.declined('lico-mcp'), isTrue);
  });

  testWidgets('one confirmation installs the accepted set', (tester) async {
    final store = MemoryPackageFirstLaunchStore();
    final installer = _FakePackageInstallSource(
      archives: const ['/tmp/offered.licopkg'],
    );
    final controller = PackageRecommendationController(
      installer: installer,
      store: store,
    );
    addTearDown(controller.dispose);
    final intents = <PluginManagementIntent>[];
    final harness = _SheetHarness(controller, intents);

    final outcome = await controller.runFirstLaunch(
      adapters: _adapters([
        _adapter(
          agentId: 'antigravity',
          plugins: [_plugin(id: 'acp-bridge', label: 'ACP Bridge')],
        ),
      ]),
    );
    expect(outcome.offered, isTrue);

    await harness.pump(tester, controller.pending);

    expect(
      find.byKey(const Key('package-recommendation-confirmation')),
      findsOneWidget,
    );
    expect(find.text('• ACP Bridge'), findsOneWidget);

    await tester.tap(find.byKey(const Key('package-recommendation-accept')));
    await tester.pumpAndSettle();

    final decision = intents.whereType<ResolvePackageRecommendation>().single;
    expect(decision.accepted, isTrue);
    expect(installer.archives, hasLength(1));
  });

  testWidgets('declining the one confirmation records a decline', (
    tester,
  ) async {
    final store = MemoryPackageFirstLaunchStore();
    final installer = _FakePackageInstallSource();
    final controller = PackageRecommendationController(
      installer: installer,
      store: store,
    );
    addTearDown(controller.dispose);
    final intents = <PluginManagementIntent>[];
    final harness = _SheetHarness(controller, intents);

    await controller.runFirstLaunch(
      adapters: _adapters([
        _adapter(
          agentId: 'antigravity',
          plugins: [_plugin(id: 'acp-bridge', label: 'ACP Bridge')],
        ),
      ]),
    );
    await harness.pump(tester, controller.pending);

    await tester.tap(find.byKey(const Key('package-recommendation-decline')));
    await tester.pumpAndSettle();

    final decision = intents.whereType<ResolvePackageRecommendation>().single;
    expect(decision.accepted, isFalse);
    await controller.resolveOffer(accepted: decision.accepted);
    expect(installer.archives, isEmpty);
    expect((await store.load()).declined('acp-bridge'), isTrue);
  });
}

/// Minimal wiring for the shell-level confirmation host: a binding whose
/// intents are recorded, and presentation sources that publish one offer.
final class _SheetHarness {
  _SheetHarness(this._controller, List<PluginManagementIntent> intents)
    : _intents = intents {
    binding = PluginManagementBinding(
      projection: _StaticProjectionSource(
        PluginManagementProjection(
          plugins: const [],
          workflows: const [],
          phase: PresentationPhase.ready,
        ),
      ),
      intents: SemanticIntentChannel<PluginManagementIntent>((intent) async {
        _intents.add(intent);
        if (intent case ResolvePackageRecommendation(:final accepted)) {
          await _controller.resolveOffer(accepted: accepted);
        }
      }),
      effects: SemanticEffectChannel<PluginManagementEffect>(),
    );
  }

  final PackageRecommendationController _controller;
  final List<PluginManagementIntent> _intents;
  late final PluginManagementBinding binding;

  Future<void> pump(
    WidgetTester tester,
    PackageRecommendationOffer? offer,
  ) async {
    final presentation = PluginManagementPresentationFixture(
      projection: PluginManagementProjection(
        plugins: const [],
        workflows: const [],
        recommendation: offer == null
            ? null
            : PackageRecommendationProjection(
                firstLaunch: offer.firstLaunch,
                recommendations: [
                  for (final item in offer.recommendations)
                    PackageRecommendationItemProjection(
                      packageId: item.packageId,
                      label: item.label,
                      agentId: item.agentId,
                      archive: item.archive,
                    ),
                ],
              ),
        phase: PresentationPhase.ready,
      ),
    );
    addTearDown(presentation.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: presentation.overrides,
        child: MaterialApp(
          locale: const Locale('en'),
          supportedLocales: LicoStrings.supportedLocales,
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          theme: buildLicoTheme(
            platformBrightness: Brightness.dark,
          ).copyWith(platform: TargetPlatform.macOS),
          home: PackageRecommendationSheetHost(
            binding: binding,
            child: const Scaffold(body: SizedBox.shrink()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }
}

final class _StaticProjectionSource
    implements ProjectionSource<PluginManagementProjection> {
  _StaticProjectionSource(this._current);

  final PluginManagementProjection _current;

  @override
  PluginManagementProjection get current => _current;

  @override
  Stream<ProjectionUpdate<PluginManagementProjection>> get changes =>
      const Stream.empty();
}

/// Accepts every install except the numbered calls the case refuses.
///
/// A test that models an available archive supplies it through [archives]; a
/// test that models the bytes not being available yet leaves the list empty,
/// which is exactly the offer the native availability cache has not filled in.
final class _FakePackageInstallSource
    implements PackageRecommendationInstallPort {
  _FakePackageInstallSource({
    this.failingCalls = const {},
    List<String> archives = const [],
  }) : _available = archives;

  final Set<int> failingCalls;
  final List<String> _available;
  final List<String> archives = [];

  @override
  Future<bool> installFromArchive(String archive) async {
    archives.add(archive);
    final index = archives.length - 1;
    if (archive.isEmpty && index < _available.length) {
      archives[archives.length - 1] = _available[index];
    }
    return !failingCalls.contains(archives.length);
  }
}

final class _ThrowingInstallSource implements PackageRecommendationInstallPort {
  @override
  Future<bool> installFromArchive(String archive) async =>
      throw StateError('package_store_unavailable');
}

List<AdapterPluginDescriptor> _adapters(List<Map<String, Object?>> adapters) =>
    AdapterPluginCatalog.fromJson({
      'ok': true,
      'schemaVersion': adapterPluginCatalogSchema,
      'adapters': adapters,
    }).adapters;

Map<String, Object?> _adapter({
  required String agentId,
  required List<Map<String, Object?>> plugins,
}) => {
  'agentId': agentId,
  'label': agentId,
  'driverId': agentId,
  'runtimeProtocol': 'acp',
  'laneFamily': 'acp',
  'managementKind': 'managed-bridge',
  'installationState': 'not-installed',
  'readiness': 'ready',
  'lifecycleActions': const ['install', 'uninstall'],
  'adapterPlugins': plugins,
};

Map<String, Object?> _plugin({required String id, required String label}) => {
  'id': id,
  'label': label,
  'detail': '',
  'installationState': 'not-installed',
  'lifecycleActions': const ['install'],
};

/// One installed entry of the native package catalogue.
///
/// An entry only exists once the store installed something, so [installed] is
/// always the installed lifecycle; availability and the enabled/active
/// preference are reported facts.
Map<String, Object?> _nativePackage({
  required String packageId,
  bool available = false,
  bool installed = true,
  bool enabled = false,
  bool active = false,
}) => {
  'packageId': packageId,
  'version': '1.0.0',
  'label': packageId,
  'capabilityKind': 'licoup-capability',
  'lifecycle': installed ? 'installed' : 'available',
  'source': 'official-directory',
  'available': available,
  'enabled': enabled,
  'active': active,
};
