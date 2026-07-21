import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/layout/profiles/native/desktop/native_desktop.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';

import './native_desktop_test_harness.dart';
import 'native_desktop_palette_fixture.dart';

const String _goldenRoot = '../../../../goldens/layout/native/desktop';

void main() {
  testWidgets('medium light Native shell golden', (tester) async {
    const size = Size(960, 640);
    configureNativeTestView(tester, size);
    final actions = NativeActionRecorder();
    final content = NativeRecordingContentPort(actions);

    await tester.pumpWidget(
      NativeDesktopTestHarness(
        environment: nativeDesktopEnvironment(
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
      find.byKey(const ValueKey<String>('native-desktop-test-viewport')),
      matchesGoldenFile('$_goldenRoot/native-medium-light.png'),
    );
  });

  testWidgets('expanded dark Native shell golden', (tester) async {
    const size = Size(1280, 720);
    configureNativeTestView(tester, size);
    final actions = NativeActionRecorder();
    final content = NativeRecordingContentPort(actions);

    await tester.pumpWidget(
      NativeDesktopTestHarness(
        environment: nativeDesktopEnvironment(
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
      find.byKey(const ValueKey<String>('native-desktop-test-viewport')),
      matchesGoldenFile('$_goldenRoot/native-expanded-dark.png'),
    );
  });

  testWidgets('deterministic Native preview golden', (tester) async {
    const size = Size(640, 400);
    configureNativeTestView(tester, size);

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildLicoTheme(
          presetId: 'geek-light-blue',
          platformBrightness: Brightness.light,
        ),
        home: Builder(
          builder: (context) => withNativeDesktopTestPalette(
            context,
            Center(
              child: SizedBox(
                width: size.width,
                child: Builder(builder: nativeDesktopBundle.previewBuilder),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    await expectLater(
      find.byKey(const ValueKey<String>('native-desktop-preview')),
      matchesGoldenFile('$_goldenRoot/native-preview-light.png'),
    );
  });
}
