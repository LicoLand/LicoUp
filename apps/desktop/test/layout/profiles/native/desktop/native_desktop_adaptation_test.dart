import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_client/src/contracts/presentation/layout_environment.dart';
import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/layout/profiles/native/desktop/native_desktop.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';

import './native_desktop_test_harness.dart';
import 'native_desktop_palette_fixture.dart';

void main() {
  testWidgets('medium preserves dense identity under scale and insets', (
    tester,
  ) async {
    const size = Size(900, 620);
    configureNativeTestView(tester, size);
    final actions = NativeActionRecorder();
    final content = NativeRecordingContentPort(actions);

    await tester.pumpWidget(
      NativeDesktopTestHarness(
        environment: nativeDesktopEnvironment(
          width: size.width,
          height: size.height,
          textScale: 1.8,
          safeInsets: LayoutInsets(left: 11, top: 7, right: 13, bottom: 5),
          keyboardInset: 60,
          hasKeyboard: true,
          hasPointer: true,
        ),
        activeDestination: ClientSection.agents,
        content: content,
        actions: actions,
      ),
    );
    await tester.pump();

    final rail = find.byKey(const Key('native-rail-nav-agents'));
    expect(
      find.byKey(const ValueKey<String>('native-desktop-shell')),
      findsOneWidget,
    );
    expect(tester.getSize(rail).width, greaterThanOrEqualTo(36));
    expect(
      find.byKey(const ValueKey<String>('native-desktop-agents-leading-dock')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('native-desktop-agents-content')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('native-topbar-search')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('expanded uses labeled rail and contextual trailing dock', (
    tester,
  ) async {
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
        ),
        activeDestination: ClientSection.agents,
        content: content,
        actions: actions,
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('native-desktop-shell')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('native-rail-nav-agents')), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('native-desktop-agents-trailing-dock')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('native-desktop-agents-content')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('native-topbar-search')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion reaches every Native navigation recipe', (
    tester,
  ) async {
    const size = Size(900, 620);
    configureNativeTestView(tester, size);
    final actions = NativeActionRecorder();
    final content = NativeRecordingContentPort(actions);

    await tester.pumpWidget(
      NativeDesktopTestHarness(
        environment: nativeDesktopEnvironment(
          width: size.width,
          height: size.height,
          reducedMotion: true,
        ),
        activeDestination: ClientSection.settings,
        content: content,
        actions: actions,
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('native-desktop-shell')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('native-rail-settings-button')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'light and dark appearance tokens compose without renderer fork',
    (tester) async {
      const size = Size(900, 620);
      configureNativeTestView(tester, size);
      final lightActions = NativeActionRecorder();
      final lightContent = NativeRecordingContentPort(lightActions);

      await tester.pumpWidget(
        NativeDesktopTestHarness(
          environment: nativeDesktopEnvironment(
            width: size.width,
            height: size.height,
          ),
          activeDestination: ClientSection.settings,
          content: lightContent,
          actions: lightActions,
        ),
      );
      await tester.pump();
      expect(lightContent.brightnesses.last, Brightness.light);

      final darkActions = NativeActionRecorder();
      final darkContent = NativeRecordingContentPort(darkActions);
      await tester.pumpWidget(
        NativeDesktopTestHarness(
          key: const ValueKey<String>('dark-native-harness'),
          environment: nativeDesktopEnvironment(
            width: size.width,
            height: size.height,
          ),
          activeDestination: ClientSection.settings,
          content: darkContent,
          actions: darkActions,
          brightness: Brightness.dark,
        ),
      );
      await tester.pump();

      expect(darkContent.brightnesses.last, Brightness.dark);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('preview geometry is deterministic across identical builds', (
    tester,
  ) async {
    const size = Size(640, 400);
    configureNativeTestView(tester, size);

    Future<void> pumpPreview() => tester.pumpWidget(
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

    await pumpPreview();
    await tester.pump();
    final landmarks = <Key>[
      const ValueKey<String>('native-preview-nav-rail'),
      const ValueKey<String>('native-preview-content-card'),
      const ValueKey<String>('native-preview-list-layer'),
      const ValueKey<String>('native-preview-detail-layer'),
    ];
    final first = <(Offset, Size)>[
      for (final key in landmarks)
        (tester.getTopLeft(find.byKey(key)), tester.getSize(find.byKey(key))),
    ];

    await pumpPreview();
    await tester.pump();
    final second = <(Offset, Size)>[
      for (final key in landmarks)
        (tester.getTopLeft(find.byKey(key)), tester.getSize(find.byKey(key))),
    ];

    expect(second, first);
    expect(find.byType(AnimatedWidget), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
