import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/profiles/classic/desktop/classic_desktop.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

import './classic_desktop_test_harness.dart';

void main() {
  testWidgets('medium keeps the compact sidebar at scaled text and insets', (
    tester,
  ) async {
    const size = Size(900, 620);
    configureClassicDesktopTestView(tester, size);
    final actions = ClassicDesktopActionRecorder();
    final content = ClassicDesktopRecordingContentPort(actions);

    await tester.pumpWidget(
      ClassicDesktopTestHarness(
        environment: classicDesktopEnvironment(
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

    expect(
      find.byKey(const Key('classic-desktop-medium-shell')),
      findsOneWidget,
    );
    expect(find.text('A'), findsOneWidget);
    expect(find.text('Arc'), findsNothing);
    expect(find.byKey(const Key('classic-nav-agents')), findsOneWidget);
    expect(
      find.byKey(const Key('classic-desktop-agents-content')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('expanded keeps the full sidebar and content composition', (
    tester,
  ) async {
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
        ),
        activeDestination: ClientSection.settings,
        content: content,
        actions: actions,
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const Key('classic-desktop-expanded-shell')),
      findsOneWidget,
    );
    expect(find.text('Arc'), findsOneWidget);
    expect(find.byKey(const Key('classic-nav-settings')), findsOneWidget);
    expect(
      find.byKey(const Key('classic-desktop-settings-content')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced-motion environment remains visible to the renderer', (
    tester,
  ) async {
    const size = Size(900, 620);
    configureClassicDesktopTestView(tester, size);
    final actions = ClassicDesktopActionRecorder();
    final content = ClassicDesktopRecordingContentPort(actions);

    await tester.pumpWidget(
      ClassicDesktopTestHarness(
        environment: classicDesktopEnvironment(
          width: size.width,
          height: size.height,
          reducedMotion: true,
        ),
        activeDestination: ClientSection.monitoring,
        content: content,
        actions: actions,
      ),
    );
    await tester.pump();

    final media = MediaQuery.of(
      tester.element(find.byKey(const Key('classic-desktop-medium-shell'))),
    );
    expect(media.disableAnimations, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('light and dark appearance compose without a renderer fork', (
    tester,
  ) async {
    const size = Size(900, 620);
    configureClassicDesktopTestView(tester, size);
    final lightActions = ClassicDesktopActionRecorder();
    final lightContent = ClassicDesktopRecordingContentPort(lightActions);

    await tester.pumpWidget(
      ClassicDesktopTestHarness(
        environment: classicDesktopEnvironment(
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

    final darkActions = ClassicDesktopActionRecorder();
    final darkContent = ClassicDesktopRecordingContentPort(darkActions);
    await tester.pumpWidget(
      ClassicDesktopTestHarness(
        key: const ValueKey<String>('dark-classic-harness'),
        environment: classicDesktopEnvironment(
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
  });

  testWidgets('preview geometry is deterministic across identical builds', (
    tester,
  ) async {
    const size = Size(640, 400);
    configureClassicDesktopTestView(tester, size);

    Future<void> pumpPreview() => tester.pumpWidget(
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

    await pumpPreview();
    await tester.pump();
    final first = tester.getRect(
      find.byKey(const Key('classic-desktop-preview')),
    );
    await pumpPreview();
    await tester.pump();
    final second = tester.getRect(
      find.byKey(const Key('classic-desktop-preview')),
    );

    expect(second, first);
    expect(find.byType(AnimatedWidget), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
