import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/layout/profiles/bubble/desktop/bubble_desktop.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

import './bubble_desktop_test_harness.dart';

const String _goldenRoot = '../../../../goldens/layout/bubble/desktop';

void main() {
  testWidgets('medium light Bubble shell golden', (tester) async {
    const size = Size(960, 640);
    configureBubbleTestView(tester, size);
    final actions = BubbleActionRecorder();
    final content = BubbleRecordingContentPort(actions);

    await tester.pumpWidget(
      BubbleDesktopTestHarness(
        environment: bubbleDesktopEnvironment(
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
      find.byKey(const ValueKey<String>('bubble-desktop-test-viewport')),
      matchesGoldenFile('$_goldenRoot/bubble-medium-light.png'),
    );
  });

  testWidgets('expanded dark Bubble shell golden', (tester) async {
    const size = Size(1280, 720);
    configureBubbleTestView(tester, size);
    final actions = BubbleActionRecorder();
    final content = BubbleRecordingContentPort(actions);

    await tester.pumpWidget(
      BubbleDesktopTestHarness(
        environment: bubbleDesktopEnvironment(
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
      find.byKey(const ValueKey<String>('bubble-desktop-test-viewport')),
      matchesGoldenFile('$_goldenRoot/bubble-expanded-dark.png'),
    );
  });

  testWidgets('deterministic Bubble preview golden', (tester) async {
    const size = Size(640, 400);
    configureBubbleTestView(tester, size);

    final theme = buildLicoTheme(
      presetId: 'geek-light-blue',
      platformBrightness: Brightness.light,
    );
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: theme,
        home: LayoutPaletteScope(
          palette: bubbleDesktopTestPalette(theme),
          child: Center(
            child: SizedBox(
              width: size.width,
              child: Builder(builder: bubbleDesktopBundle.previewBuilder),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    await expectLater(
      find.byKey(const ValueKey<String>('bubble-desktop-preview')),
      matchesGoldenFile('$_goldenRoot/bubble-preview-light.png'),
    );
  });
}
