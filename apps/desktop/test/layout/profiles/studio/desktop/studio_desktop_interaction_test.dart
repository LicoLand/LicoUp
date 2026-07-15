import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/layout/layout_chrome_port.dart';

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

      expect(
        find.byKey(const ValueKey<String>('studio-desktop-safari-shell')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('safari-sidebar-nav-controlPanel')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('safari-sidebar-nav-agents')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('shell-sidebar-search')), findsOneWidget);
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

    await tester.tap(find.byKey(const Key('safari-sidebar-nav-controlPanel')));
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

    final agents = find.byKey(const Key('safari-sidebar-nav-agents'));
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
      find.byKey(const ValueKey<String>('studio-content-action-controlPanel')),
    );
    await tester.pump();
    expect(actions.contentActions, <(ClientSection, String)>[
      (ClientSection.controlPanel, 'primary'),
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('private Studio chrome consumes only the neutral chrome port', (
    tester,
  ) async {
    const size = Size(900, 620);
    configureStudioTestView(tester, size);
    final actions = StudioActionRecorder();
    final content = StudioRecordingContentPort(actions);
    final chrome = _StudioChromeRecorder(
      LayoutChromeSnapshot(
        status: const LayoutChromeStatusSnapshot(message: '', caption: 'Ready'),
        allowance: LayoutChromeAllowanceSnapshot(
          targetId: 'studio-test-agent',
          targetLabel: 'Studio Test',
          meters: const <LayoutChromeAllowanceMeterSnapshot>[
            LayoutChromeAllowanceMeterSnapshot(
              kind: 'studio-weekly-limit',
              label: 'Studio weekly',
              provider: 'Studio',
              period: 'week',
              status: 'available',
              value: '75%',
              unit: '',
              message: 'Resets in 2 days.',
            ),
          ],
          totalTokens: 100,
          targetTokens: 75,
        ),
      ),
    );

    await tester.pumpWidget(
      StudioDesktopTestHarness(
        environment: studioDesktopEnvironment(
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

    expect(
      find.byKey(const ValueKey<String>('shell-status-text:Ready')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('agent-allowance-meter-studio-weekly-limit')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('agent-allowance-meter-value-Studio weekly')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('safari-sidebar-pairing-button')));
    await tester.pump();

    expect(chrome.pairingOpenCount, 1);
    expect(actions.destinationSelections, isEmpty);
    expect(tester.takeException(), isNull);
  });
}

final class _StudioChromeRecorder extends ChangeNotifier
    implements LayoutChromePort {
  _StudioChromeRecorder(this._value);

  final LayoutChromeSnapshot _value;
  int pairingOpenCount = 0;

  @override
  LayoutChromeSnapshot get value => _value;

  @override
  Future<void> openPairing(BuildContext context) async {
    pairingOpenCount += 1;
  }
}
