import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/profiles/classic/desktop/classic_desktop.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

import './classic_desktop_test_harness.dart';

const String _goldenRoot = '../../../../goldens/layout/classic/desktop';

void main() {
  testWidgets('medium light Classic shell golden', (tester) async {
    const size = Size(960, 640);
    configureClassicDesktopTestView(tester, size);
    final actions = ClassicDesktopActionRecorder();
    final content = ClassicDesktopRecordingContentPort(actions);

    await tester.pumpWidget(
      ClassicDesktopTestHarness(
        environment: classicDesktopEnvironment(
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
      find.byKey(const Key('classic-desktop-test-viewport')),
      matchesGoldenFile('$_goldenRoot/classic-medium-light.png'),
    );
  });

  testWidgets('expanded dark Classic shell golden', (tester) async {
    const size = Size(1280, 720);
    configureClassicDesktopTestView(tester, size);
    final actions = ClassicDesktopActionRecorder();
    final content = ClassicDesktopRecordingContentPort(actions);

    await tester.pumpWidget(
      ClassicDesktopTestHarness(
        environment: classicDesktopEnvironment(
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
      find.byKey(const Key('classic-desktop-test-viewport')),
      matchesGoldenFile('$_goldenRoot/classic-expanded-dark.png'),
    );
  });

  testWidgets('deterministic Classic preview golden', (tester) async {
    const size = Size(640, 400);
    configureClassicDesktopTestView(tester, size);

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildLicoTheme(
          presetId: 'geek-light-blue',
          platformBrightness: Brightness.light,
        ),
        home: Center(
          child: SizedBox(
            width: size.width,
            child: Builder(builder: classicDesktopBundle.previewBuilder),
          ),
        ),
      ),
    );
    await tester.pump();

    await expectLater(
      find.byKey(const Key('classic-desktop-preview')),
      matchesGoldenFile('$_goldenRoot/classic-preview-light.png'),
    );
  });
}
