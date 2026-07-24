import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_chrome_port.dart';

import './classic_desktop_test_harness.dart';

void main() {
  testWidgets('semantic landmarks cover navigation and destination content', (
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
    expect(find.byKey(const Key('classic-nav-agents')), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('navigation and parent-owned content actions remain typed', (
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
          hasPointer: true,
          hasTouch: true,
        ),
        activeDestination: ClientSection.agents,
        content: content,
        actions: actions,
      ),
    );
    await tester.pump();

    final agents = find.byKey(const Key('classic-nav-agents'));
    expect(tester.getSize(agents).height, greaterThanOrEqualTo(40));
    final pointer = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await pointer.addPointer(location: tester.getCenter(agents));
    await pointer.moveTo(tester.getCenter(agents));
    await pointer.down(tester.getCenter(agents));
    await pointer.up();
    await tester.pump();
    await pointer.removePointer();

    expect(actions.destinationSelections, [ClientSection.agents]);
    await tester.tap(find.byKey(const Key('classic-content-action-agents')));
    await tester.pump();
    expect(actions.contentActions, [(ClientSection.agents, 'primary')]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('each visible navigation entry selects its semantic target', (
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
        ),
        activeDestination: ClientSection.agents,
        content: content,
        actions: actions,
      ),
    );

    for (final destination in classicDesktopExpectedDestinations) {
      await tester.tap(
        find.byKey(ValueKey<String>('classic-nav-${destination.name}')),
      );
      await tester.pump();
    }
    expect(
      actions.destinationSelections.toSet(),
      classicDesktopExpectedDestinations,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('private status chrome follows the neutral live snapshot', (
    tester,
  ) async {
    const size = Size(1280, 720);
    configureClassicDesktopTestView(tester, size);
    final actions = ClassicDesktopActionRecorder();
    final content = ClassicDesktopRecordingContentPort(actions);
    final chrome = _ClassicChromeFake(
      const LayoutChromeSnapshot(
        status: LayoutChromeStatusSnapshot(
          message: 'Ready',
          caption: 'Classic client',
        ),
      ),
    );
    addTearDown(chrome.dispose);

    await tester.pumpWidget(
      ClassicDesktopTestHarness(
        environment: classicDesktopEnvironment(
          width: size.width,
          height: size.height,
        ),
        activeDestination: ClientSection.agents,
        content: content,
        actions: actions,
        chrome: chrome,
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('shell-status-text:Ready')),
      findsOneWidget,
    );
    chrome.snapshot = const LayoutChromeSnapshot(
      status: LayoutChromeStatusSnapshot(
        message: 'Updated',
        caption: 'Classic client',
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('shell-status-text:Updated')),
      findsOneWidget,
    );
  });
}

final class _ClassicChromeFake extends ChangeNotifier
    implements LayoutChromePort {
  _ClassicChromeFake(this._snapshot);

  LayoutChromeSnapshot _snapshot;

  @override
  LayoutChromeSnapshot get value => _snapshot;

  set snapshot(LayoutChromeSnapshot value) {
    if (_snapshot == value) {
      return;
    }
    _snapshot = value;
    notifyListeners();
  }

  @override
  Future<void> openPairing(BuildContext context) async {}

  @override
  Future<void> openGlobalSearch(BuildContext context) async {}
}
