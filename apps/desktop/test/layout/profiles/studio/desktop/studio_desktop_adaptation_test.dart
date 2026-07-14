import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_client/src/contracts/presentation/layout_environment.dart';
import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/layout/profiles/studio/desktop/studio_desktop.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';

import './studio_desktop_test_harness.dart';

void main() {
  testWidgets('medium preserves dense identity under scale and insets', (
    tester,
  ) async {
    const size = Size(900, 620);
    configureStudioTestView(tester, size);
    final actions = StudioActionRecorder();
    final content = StudioRecordingContentPort(actions);

    await tester.pumpWidget(
      StudioDesktopTestHarness(
        environment: studioDesktopEnvironment(
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

    final rail = find.byKey(
      const ValueKey<String>('studio-desktop-context-rail'),
    );
    final workspace = find.byKey(
      const ValueKey<String>('studio-desktop-docked-workspace'),
    );
    expect(tester.getSize(rail).width, 64);
    expect(tester.getTopLeft(rail), const Offset(11, 7));
    expect(
      tester.getBottomRight(workspace).dy,
      lessThanOrEqualTo(size.height - 60),
    );
    expect(
      find.byKey(const ValueKey<String>('studio-desktop-agents-leading-dock')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('expanded uses labeled rail and contextual trailing dock', (
    tester,
  ) async {
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
        ),
        activeDestination: ClientSection.agents,
        content: content,
        actions: actions,
      ),
    );
    await tester.pump();

    final rail = find.byKey(
      const ValueKey<String>('studio-desktop-context-rail'),
    );
    expect(tester.getSize(rail).width, greaterThanOrEqualTo(176));
    expect(
      find.byKey(const ValueKey<String>('studio-desktop-agents-trailing-dock')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('studio-desktop-workspace-bar')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion reaches every Studio navigation recipe', (
    tester,
  ) async {
    const size = Size(900, 620);
    configureStudioTestView(tester, size);
    final actions = StudioActionRecorder();
    final content = StudioRecordingContentPort(actions);

    await tester.pumpWidget(
      StudioDesktopTestHarness(
        environment: studioDesktopEnvironment(
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

    final animated = tester.widgetList<AnimatedContainer>(
      find.byType(AnimatedContainer),
    );
    expect(animated, isNotEmpty);
    expect(
      animated.every((widget) => widget.duration == Duration.zero),
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'light and dark appearance tokens compose without renderer fork',
    (tester) async {
      const size = Size(900, 620);
      configureStudioTestView(tester, size);
      final lightActions = StudioActionRecorder();
      final lightContent = StudioRecordingContentPort(lightActions);

      await tester.pumpWidget(
        StudioDesktopTestHarness(
          environment: studioDesktopEnvironment(
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

      final darkActions = StudioActionRecorder();
      final darkContent = StudioRecordingContentPort(darkActions);
      await tester.pumpWidget(
        StudioDesktopTestHarness(
          key: const ValueKey<String>('dark-studio-harness'),
          environment: studioDesktopEnvironment(
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
    configureStudioTestView(tester, size);

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
            child: Builder(builder: studioDesktopBundle.previewBuilder),
          ),
        ),
      ),
    );

    await pumpPreview();
    await tester.pump();
    final landmarks = <Key>[
      const ValueKey<String>('studio-preview-context-rail'),
      const ValueKey<String>('studio-preview-workspace-bar'),
      const ValueKey<String>('studio-preview-edge-editor'),
      const ValueKey<String>('studio-preview-inspector-dock'),
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
