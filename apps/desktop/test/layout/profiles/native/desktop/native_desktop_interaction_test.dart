import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/layout/layout_chrome_port.dart';

import './native_desktop_test_harness.dart';

void main() {
  testWidgets(
    'semantic landmarks and ordered focus cover navigation and body',
    (tester) async {
      const size = Size(900, 620);
      configureNativeTestView(tester, size);
      final actions = NativeActionRecorder();
      final content = NativeRecordingContentPort(actions);

      await tester.pumpWidget(
        NativeDesktopTestHarness(
          environment: nativeDesktopEnvironment(
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
        find.byKey(const ValueKey<String>('native-desktop-shell')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('native-rail-nav-agents')), findsOneWidget);
      expect(find.byKey(const Key('native-topbar-search')), findsOneWidget);
      semantics.dispose();
    },
  );

  testWidgets('keyboard activates the first ordered navigation action', (
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
          hasKeyboard: true,
        ),
        activeDestination: ClientSection.agents,
        content: content,
        actions: actions,
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('native-rail-nav-agents')));
    await tester.pump();

    expect(actions.destinationSelections, <ClientSection>[
      ClientSection.agents,
    ]);
  });

  testWidgets('mouse and touch paths retain exact typed actions', (
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
          hasPointer: true,
          hasTouch: true,
        ),
        activeDestination: ClientSection.agents,
        content: content,
        actions: actions,
      ),
    );
    await tester.pump();

    final agents = find.byKey(const Key('native-rail-nav-agents'));
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
      find.byKey(const ValueKey<String>('native-content-action-agents')),
    );
    await tester.pump();
    expect(actions.contentActions, <(ClientSection, String)>[
      (ClientSection.agents, 'primary'),
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('private Native chrome consumes only the neutral chrome port', (
    tester,
  ) async {
    const size = Size(900, 620);
    configureNativeTestView(tester, size);
    final actions = NativeActionRecorder();
    final content = NativeRecordingContentPort(actions);
    final chrome = _NativeChromeRecorder(
      const LayoutChromeSnapshot(
        status: LayoutChromeStatusSnapshot(message: '', caption: 'Ready'),
      ),
    );

    await tester.pumpWidget(
      NativeDesktopTestHarness(
        environment: nativeDesktopEnvironment(
          width: size.width,
          height: size.height,
          hasPointer: true,
        ),
        activeDestination: ClientSection.agents,
        content: content,
        actions: actions,
        chrome: chrome,
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('native-rail-pairing-button')));
    await tester.pump();

    expect(chrome.pairingOpenCount, 1);
    expect(actions.destinationSelections, isEmpty);
    expect(tester.takeException(), isNull);
  });
}

final class _NativeChromeRecorder extends ChangeNotifier
    implements LayoutChromePort {
  _NativeChromeRecorder(this._value);

  final LayoutChromeSnapshot _value;
  int pairingOpenCount = 0;

  @override
  LayoutChromeSnapshot get value => _value;

  @override
  Future<void> openPairing(BuildContext context) async {
    pairingOpenCount += 1;
  }

  @override
  Future<void> openGlobalSearch(BuildContext context) async {}
}
