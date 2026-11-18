import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/presentation/built_in_layout_spec.dart';
import 'package:licoup/src/contracts/presentation/dashboard_feature_order.dart';
import 'package:licoup/src/contracts/presentation/desktop_dock_layout.dart';
import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/layout_style.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/composition/built_in_layout_composition.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_render_adapter.dart';
import 'package:licoup/src/frontend/shared/client_platform_ports.dart';
import 'package:licoup/src/frontend/shared/dashboard_feature_order_store.dart';
import 'package:licoup/src/frontend/shared/desktop_dock_layout_store.dart';

import '../fixtures/production_client_shell_fixture.dart';
import '../../support/bundled_font_loader.dart';

void main() {
  final composition = BuiltInLayoutComposition();

  setUpAll(() async {
    await loadBundledVisualFonts();
    // Keep isolated and suite runs on the same production adapter. Otherwise
    // the first case can paint with the fallback while later cases reuse the
    // asynchronously loaded adapter cache.
    await AgentRenderAdapterRegistry.instance.loadAdapters();
  });

  for (final definition in composition.definitions) {
    for (final bundle in definition.bundles.values) {
      final profileId = definition.profile.id;
      final surface = bundle.surface;
      for (final baseline in _baselinesFor(profileId, surface)) {
        final destination = baseline.destination;

        testWidgets('${profileId.value}/${surface.name}/${destination.name}'
            '${baseline.goldenSuffix} renders the production shell baseline', (
          tester,
        ) async {
          final fixture = await ProductionClientShellFixture.create(
            profileId: profileId,
            surface: surface,
            destination: destination,
            size: baseline.size,
            brightness: baseline.brightness,
            layoutStyleId: baseline.styleId,
          );
          final semanticsKey = ValueKey<String>(
            'production-baseline-semantics-'
            '${profileId.value}-${surface.name}-${destination.name}',
          );
          final repaintBoundaryKey = ValueKey<String>(
            'production-baseline-repaint-'
            '${profileId.value}-${surface.name}-${destination.name}',
          );
          addTearDown(fixture.dispose);
          await tester.binding.setSurfaceSize(baseline.size);
          addTearDown(() => tester.binding.setSurfaceSize(null));

          final app = fixture.buildApp(
            semanticsKey: semanticsKey,
            repaintBoundaryKey: repaintBoundaryKey,
          );

          // Building the app constructs the composition, which installs
          // disk-backed stores; widget tests run in a fake-async zone where
          // real file I/O never completes. Substitute persistence after the
          // composition exists and before the first frame — the dock stays
          // hidden until its layout load finishes.
          final dockStore = _MemoryDockStore();
          final featureStore = _MemoryFeatureStore();
          ClientPlatformPorts.dockLayoutStore = () => dockStore;
          ClientPlatformPorts.featureOrderStore = () => featureStore;

          await tester.pumpWidget(app);
          final viewport = LayoutViewportPolicy.classify(
            surface: surface,
            width: baseline.size.width,
          );
          expect(
            find.byKey(
              Key(
                'layout-host-${profileId.value}/${surface.name}/${viewport.name}',
              ),
            ),
            findsOneWidget,
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 120));
          await tester.pump();

          expect(find.byKey(semanticsKey), findsOneWidget);
          expect(find.byKey(repaintBoundaryKey), findsOneWidget);
          expect(tester.takeException(), isNull);

          try {
            await expectLater(
              find.byKey(repaintBoundaryKey),
              matchesGoldenFile(
                '../../goldens/layout/'
                '${profileId.value}/${surface.name}/'
                'production-baseline/'
                '${destination.name}${baseline.goldenSuffix}.png',
              ),
            );
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pump();
          }
        });
      }
    }
  }
}

List<_ProductionBaseline> _baselinesFor(
  LayoutProfileId profileId,
  LayoutRuntimeSurface surface,
) => switch (surface) {
  // Dashboard desktop baselines are pinned to card so the original
  // PNGs stay the baseline of the preserved style; the plain
  // style gets its own agents/settings baselines.
  LayoutRuntimeSurface.desktop =>
    profileId == BuiltInLayoutSpec.dashboard.id
        ? [
            _ProductionBaseline(
              destination: ClientSection.agents,
              size: Size(1180, 820),
              brightness: Brightness.dark,
              styleId: BuiltInLayoutSpec.dashboardCardStyleId,
            ),
            _ProductionBaseline(
              destination: ClientSection.settings,
              size: Size(1180, 820),
              brightness: Brightness.light,
              styleId: BuiltInLayoutSpec.dashboardCardStyleId,
            ),
            _ProductionBaseline(
              destination: ClientSection.agents,
              size: Size(1180, 820),
              brightness: Brightness.dark,
              styleId: BuiltInLayoutSpec.dashboardPlainStyleId,
              goldenSuffix: '-plain',
            ),
            _ProductionBaseline(
              destination: ClientSection.settings,
              size: Size(1180, 820),
              brightness: Brightness.light,
              styleId: BuiltInLayoutSpec.dashboardPlainStyleId,
              goldenSuffix: '-plain',
            ),
          ]
        : const [
            _ProductionBaseline(
              destination: ClientSection.agents,
              size: Size(1180, 820),
              brightness: Brightness.dark,
            ),
            _ProductionBaseline(
              destination: ClientSection.settings,
              size: Size(1180, 820),
              brightness: Brightness.light,
            ),
            _ProductionBaseline(
              destination: ClientSection.agentHub,
              size: Size(1180, 820),
              brightness: Brightness.dark,
            ),
          ],
  LayoutRuntimeSurface.mobile => const [
    _ProductionBaseline(
      destination: ClientSection.agents,
      size: Size(540, 960),
      brightness: Brightness.dark,
    ),
    _ProductionBaseline(
      destination: ClientSection.settings,
      size: Size(540, 960),
      brightness: Brightness.light,
    ),
  ],
};

final class _ProductionBaseline {
  const _ProductionBaseline({
    required this.destination,
    required this.size,
    required this.brightness,
    this.styleId,
    this.goldenSuffix = '',
  });

  final ClientSection destination;
  final Size size;
  final Brightness brightness;

  /// The persisted column style for baselines that must pin one; profiles
  /// without styles leave it null.
  final LayoutStyleId? styleId;

  /// Suffix appended to the golden filename, e.g. `-plain`.
  final String goldenSuffix;
}

final class _MemoryDockStore extends DesktopDockLayoutStore {
  DesktopDockLayoutSnapshot value = const DesktopDockLayoutSnapshot(
    entries: [],
  );
  @override
  Future<DesktopDockLayoutSnapshot> load(Object portableData) async => value;
  @override
  Future<void> save(
    Object portableData,
    DesktopDockLayoutSnapshot snapshot,
  ) async {
    value = snapshot;
  }
}

final class _MemoryFeatureStore extends DashboardFeatureOrderStore {
  List<String> value = DashboardFeatureOrder.defaultOrder;
  @override
  Future<List<String>> load(Object portableData) async => value;
  @override
  Future<void> save(Object portableData, List<String> order) async {
    value = List.of(order);
  }
}
