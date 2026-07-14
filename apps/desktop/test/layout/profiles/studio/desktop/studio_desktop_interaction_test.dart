import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';

import './studio_desktop_test_harness.dart';

void main() {
  testWidgets(
    'semantic landmarks and ordered focus cover navigation and body',
    (tester) async {
      const size = Size(900, 620);
      configureStudioTestView(tester, size);
      final actions = StudioActionRecorder();
      final content = StudioRecordingContentPort(actions);

      await tester.pumpWidget(
        StudioDesktopTestHarness(
          environment: studioDesktopEnvironment(
            width: size.width,
            height: size.height,
            hasKeyboard: true,
          ),
          activeDestination: ClientSection.controlPanel,
          content: content,
          actions: actions,
        ),
      );
      await tester.pump();

      final semantics = tester.ensureSemantics();
      expect(find.bySemanticsLabel('Home'), findsAtLeastNWidgets(1));
      expect(find.bySemanticsLabel('Content Home'), findsOneWidget);

      final orders = tester
          .widgetList<FocusTraversalOrder>(find.byType(FocusTraversalOrder))
          .map((widget) => (widget.order as NumericFocusOrder).order)
          .toList(growable: false);
      expect(orders, containsAll(<double>[0, 1, 2, 3, 4, 5, 6, 1000]));
      expect(orders.toList()..sort(), orders);
      semantics.dispose();
    },
  );

  testWidgets('keyboard activates the first ordered navigation action', (
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
          hasKeyboard: true,
        ),
        activeDestination: ClientSection.controlPanel,
        content: content,
        actions: actions,
      ),
    );
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(actions.destinationSelections, <ClientSection>[
      ClientSection.controlPanel,
    ]);
  });

  testWidgets('mouse and touch paths retain exact typed actions', (
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
          hasPointer: true,
          hasTouch: true,
        ),
        activeDestination: ClientSection.controlPanel,
        content: content,
        actions: actions,
      ),
    );
    await tester.pump();

    final agents = find.byKey(
      const ValueKey<String>('studio-desktop-navigation-agents'),
    );
    expect(tester.getSize(agents).height, greaterThanOrEqualTo(44));

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
      find.byKey(const ValueKey<String>('studio-content-action-controlPanel')),
    );
    await tester.pump();
    expect(actions.contentActions, <(ClientSection, String)>[
      (ClientSection.controlPanel, 'primary'),
    ]);
    expect(tester.takeException(), isNull);
  });
}
