import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_client/src/contracts/presentation/layout_environment.dart';
import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/layout/layout_palette.dart';
import 'package:flutter_client/src/frontend/layout/profiles/bubble/desktop/bubble_desktop.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';

import './bubble_desktop_test_harness.dart';

void main() {
  testWidgets('medium preserves dense identity under scale and insets', (
    tester,
  ) async {
    const size = Size(900, 620);
    configureBubbleTestView(tester, size);
    final actions = BubbleActionRecorder();
    final content = BubbleRecordingContentPort(actions);

    await tester.pumpWidget(
      BubbleDesktopTestHarness(
        environment: bubbleDesktopEnvironment(
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

    final rail = find.byKey(const Key('sidebar-rail-nav-agents'));
    expect(
      find.byKey(const ValueKey<String>('bubble-desktop-sidebar-rail-shell')),
      findsOneWidget,
    );
    expect(tester.getSize(rail).width, greaterThanOrEqualTo(36));
    expect(
      find.byKey(const ValueKey<String>('bubble-desktop-agents-leading-dock')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('shell-sidebar-search')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('expanded uses labeled rail and contextual trailing dock', (
    tester,
  ) async {
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
        ),
        activeDestination: ClientSection.agents,
        content: content,
        actions: actions,
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('bubble-desktop-sidebar-rail-shell')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('sidebar-rail-nav-agents')), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('bubble-desktop-agents-trailing-dock')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('shell-sidebar-search')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion reaches every Bubble navigation recipe', (
    tester,
  ) async {
    const size = Size(900, 620);
    configureBubbleTestView(tester, size);
    final actions = BubbleActionRecorder();
    final content = BubbleRecordingContentPort(actions);

    await tester.pumpWidget(
      BubbleDesktopTestHarness(
        environment: bubbleDesktopEnvironment(
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
      find.byKey(const ValueKey<String>('bubble-desktop-sidebar-rail-shell')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('sidebar-rail-settings-button')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'light and dark appearance tokens compose without renderer fork',
    (tester) async {
      const size = Size(900, 620);
      configureBubbleTestView(tester, size);
      final lightActions = BubbleActionRecorder();
      final lightContent = BubbleRecordingContentPort(lightActions);

      await tester.pumpWidget(
        BubbleDesktopTestHarness(
          environment: bubbleDesktopEnvironment(
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

      final darkActions = BubbleActionRecorder();
      final darkContent = BubbleRecordingContentPort(darkActions);
      await tester.pumpWidget(
        BubbleDesktopTestHarness(
          key: const ValueKey<String>('dark-bubble-harness'),
          environment: bubbleDesktopEnvironment(
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
    configureBubbleTestView(tester, size);

    final theme = buildLicoTheme(
      presetId: 'geek-light-blue',
      platformBrightness: Brightness.light,
    );
    Future<void> pumpPreview() => tester.pumpWidget(
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

    await pumpPreview();
    await tester.pump();
    final landmarks = <Key>[
      const ValueKey<String>('bubble-preview-context-rail'),
      const ValueKey<String>('bubble-preview-workspace-bar'),
      const ValueKey<String>('bubble-preview-edge-editor'),
      const ValueKey<String>('bubble-preview-inspector-dock'),
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
