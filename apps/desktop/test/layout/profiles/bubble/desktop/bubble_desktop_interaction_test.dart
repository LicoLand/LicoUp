import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/layout/layout_chrome_port.dart';

import './bubble_desktop_test_harness.dart';

void main() {
  testWidgets(
    'semantic landmarks and ordered focus cover navigation and body',
    (tester) async {
      const size = Size(900, 620);
      configureBubbleTestView(tester, size);
      final actions = BubbleActionRecorder();
      final content = BubbleRecordingContentPort(actions);

      await tester.pumpWidget(
        BubbleDesktopTestHarness(
          environment: bubbleDesktopEnvironment(
            width: size.width,
            height: size.height,
            hasKeyboard: true,
          ),
          activeDestination: ClientSection.agents,
          content: content,
          actions: actions,
        ),
      );
      await tester.pump();

      final semantics = tester.ensureSemantics();
      expect(find.bySemanticsLabel('Agents'), findsAtLeastNWidgets(1));
      expect(find.bySemanticsLabel('Content Agents'), findsOneWidget);

      expect(
        find.byKey(const ValueKey<String>('bubble-desktop-sidebar-rail-shell')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('sidebar-rail-nav-agents')), findsOneWidget);
      expect(find.byKey(const Key('shell-sidebar-search')), findsOneWidget);
      semantics.dispose();
    },
  );

  testWidgets('keyboard activates the first ordered navigation action', (
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
          hasKeyboard: true,
        ),
        activeDestination: ClientSection.agents,
        content: content,
        actions: actions,
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('sidebar-rail-nav-agents')));
    await tester.pump();

    expect(actions.destinationSelections, <ClientSection>[
      ClientSection.agents,
    ]);
  });

  testWidgets('mouse and touch paths retain exact typed actions', (
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
          hasPointer: true,
          hasTouch: true,
        ),
        activeDestination: ClientSection.agents,
        content: content,
        actions: actions,
      ),
    );
    await tester.pump();

    final agents = find.byKey(const Key('sidebar-rail-nav-agents'));
    expect(tester.getSize(agents).height, greaterThanOrEqualTo(36));

    final pointer = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await pointer.addPointer(location: tester.getCenter(agents));
    await pointer.moveTo(tester.getCenter(agents));
    await tester.pump();
    await pointer.down(tester.getCenter(agents));
    await pointer.up();
    await tester.pump();
    await pointer.removePointer();

    expect(actions.destinationSelections, <ClientSection>[
      ClientSection.agents,
    ]);

    await tester.tap(
      find.byKey(const ValueKey<String>('bubble-content-action-agents')),
    );
    await tester.pump();
    expect(actions.contentActions, <(ClientSection, String)>[
      (ClientSection.agents, 'primary'),
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pairing and status chrome consume only the semantic port', (
    tester,
  ) async {
    const size = Size(900, 620);
    configureBubbleTestView(tester, size);
    final actions = BubbleActionRecorder();
    final content = BubbleRecordingContentPort(actions);
    final chrome = BubbleRecordingChromePort(
      const LayoutChromeSnapshot(
        status: LayoutChromeStatusSnapshot(
          message: 'Ready',
          caption: 'Connected',
        ),
      ),
    );

    await tester.pumpWidget(
      BubbleDesktopTestHarness(
        environment: bubbleDesktopEnvironment(
          width: size.width,
          height: size.height,
        ),
        activeDestination: ClientSection.agents,
        content: content,
        actions: actions,
        chrome: chrome,
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('shell-status-text:Ready')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('sidebar-rail-pairing-button')));
    await tester.pump();

    expect(chrome.pairingInvocations, 1);
    expect(actions.destinationSelections, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
