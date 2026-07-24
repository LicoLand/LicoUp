import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/profiles/classic/mobile/classic_mobile_bundle.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

import './classic_mobile_test_harness.dart';

const String _goldenRoot = '../../../../goldens/layout/classic/mobile';

void main() {
  testWidgets('compact light Classic shell golden', (tester) async {
    final harness = ClassicMobileHarness(
      activeDestination: ClientSection.agents,
    );
    await pumpClassicMobileHarness(
      tester,
      harness: harness,
      environment: classicMobileEnvironment(
        width: 390,
        height: 640,
        reducedMotion: true,
      ),
    );

    await expectLater(
      find.byKey(const Key('classic-mobile-compact-shell')),
      matchesGoldenFile('$_goldenRoot/classic-compact-light.png'),
    );
  });

  testWidgets('medium dark Classic shell golden', (tester) async {
    final harness = ClassicMobileHarness(
      activeDestination: ClientSection.settings,
    );
    await pumpClassicMobileHarness(
      tester,
      harness: harness,
      environment: classicMobileEnvironment(
        width: 720,
        height: 640,
        hasPointer: true,
        hasKeyboard: true,
        hasTouch: false,
        reducedMotion: true,
      ),
      brightness: Brightness.dark,
    );

    await expectLater(
      find.byKey(const Key('classic-mobile-medium-shell')),
      matchesGoldenFile('$_goldenRoot/classic-medium-dark.png'),
    );
  });

  for (final brightness in Brightness.values) {
    testWidgets('Classic mobile preview ${brightness.name} golden', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(480, 320);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final theme = buildLicoTheme(platformBrightness: brightness);

      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: ColoredBox(
            color: brightness == Brightness.dark
                ? const Color(0xFF090B10)
                : const Color(0xFFF4F5F7),
            child: Center(
              child: RepaintBoundary(
                key: const Key('classic-mobile-preview-frame'),
                child: SizedBox(
                  width: 336,
                  child: Builder(builder: classicMobileBundle.previewBuilder),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      await expectLater(
        find.byKey(const Key('classic-mobile-preview-frame')),
        matchesGoldenFile(
          '$_goldenRoot/classic-preview-${brightness.name}.png',
        ),
      );
    });
  }
}
