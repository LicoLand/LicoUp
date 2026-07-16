import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_client/src/contracts/presentation/layout_environment.dart';
import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/application/composition/built_in_layout_composition.dart';

import '../fixtures/production_client_shell_fixture.dart';

void main() {
  final composition = BuiltInLayoutComposition();

  for (final definition in composition.definitions) {
    for (final bundle in definition.bundles.values) {
      for (final baseline in _baselinesFor(bundle.surface)) {
        final profileId = definition.profile.id;
        final surface = bundle.surface;
        final destination = baseline.destination;

        testWidgets('${profileId.value}/${surface.name}/${destination.name} '
            'renders the production shell baseline', (tester) async {
          final fixture = await ProductionClientShellFixture.create(
            profileId: profileId,
            surface: surface,
            destination: destination,
            size: baseline.size,
            brightness: baseline.brightness,
          );
          final semanticsKey = ValueKey<String>(
            'production-baseline-semantics-'
            '${profileId.value}-${surface.name}-${destination.name}',
          );
          final repaintBoundaryKey = ValueKey<String>(
            'production-baseline-repaint-'
            '${profileId.value}-${surface.name}-${destination.name}',
          );
          addTearDown(fixture.controller.dispose);
          await tester.binding.setSurfaceSize(baseline.size);
          addTearDown(() => tester.binding.setSurfaceSize(null));

          await tester.pumpWidget(
            fixture.buildApp(
              semanticsKey: semanticsKey,
              repaintBoundaryKey: repaintBoundaryKey,
            ),
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
                '../../goldens/layout/production-baseline/'
                '${profileId.value}/${surface.name}/${destination.name}.png',
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

List<_ProductionBaseline> _baselinesFor(LayoutRuntimeSurface surface) =>
    switch (surface) {
      LayoutRuntimeSurface.desktop => const [
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
  });

  final ClientSection destination;
  final Size size;
  final Brightness brightness;
}
