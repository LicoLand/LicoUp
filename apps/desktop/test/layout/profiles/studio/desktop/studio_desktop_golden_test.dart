import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/layout/profiles/studio/desktop/studio_desktop.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';

import './studio_desktop_test_harness.dart';
import 'studio_desktop_palette_fixture.dart';

const String _goldenRoot = '../../../../goldens/layout/studio/desktop';

void main() {
  testWidgets('medium light Studio shell golden', (tester) async {
    const size = Size(960, 640);
    configureStudioTestView(tester, size);
    final actions = StudioActionRecorder();
    final content = StudioRecordingContentPort(actions);

    await tester.pumpWidget(
      StudioDesktopTestHarness(
        environment: studioDesktopEnvironment(
          width: size.width,
          height: size.height,
          hasKeyboard: true,
          hasPointer: true,
          reducedMotion: true,
        ),
        activeDestination: ClientSection.monitoring,
        content: content,
        actions: actions,
      ),
    );
    await tester.pump();

    await expectLater(
      find.byKey(const ValueKey<String>('studio-desktop-test-viewport')),
      matchesGoldenFile('$_goldenRoot/studio-medium-light.png'),
    );
  });

  testWidgets('expanded dark Studio shell golden', (tester) async {
    const size = Size(1280, 720);
    configureStudioTestView(tester, size);
    final actions = StudioActionRecorder();
    final content = StudioRecordingContentPort(actions);

    await tester.pumpWidget(
      StudioDesktopTestHarness(
        environment: studioDesktopEnvironment(
          width: size.width,
          height: size.height,
          hasKeyboard: true,
          hasPointer: true,
          reducedMotion: true,
        ),
        activeDestination: ClientSection.agents,
        content: content,
        actions: actions,
        brightness: Brightness.dark,
      ),
    );
    await tester.pump();

    await expectLater(
      find.byKey(const ValueKey<String>('studio-desktop-test-viewport')),
      matchesGoldenFile('$_goldenRoot/studio-expanded-dark.png'),
    );
  });

  testWidgets('deterministic Studio preview golden', (tester) async {
    const size = Size(640, 400);
    configureStudioTestView(tester, size);

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildLicoTheme(
          presetId: 'geek-light-blue',
          platformBrightness: Brightness.light,
        ),
        home: Builder(
          builder: (context) => withStudioDesktopTestPalette(
            context,
            Center(
              child: SizedBox(
                width: size.width,
                child: Builder(builder: studioDesktopBundle.previewBuilder),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    await expectLater(
      find.byKey(const ValueKey<String>('studio-desktop-preview')),
      matchesGoldenFile('$_goldenRoot/studio-preview-light.png'),
    );
  });
}
