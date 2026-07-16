import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/layout/layout_chrome_port.dart';

import './workbench_desktop_test_harness.dart';

void main() {
  testWidgets('medium and expanded variants host tuned top-bar chrome', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    for (final size in const [Size(900, 720), Size(1280, 800)]) {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      final environment = workbenchDesktopEnvironment(
        width: size.width,
        height: size.height,
      );
      final counter = DestinationBuildCounter();

      await tester.pumpWidget(
        WorkbenchDesktopShellHarness(
          environment: environment,
          destination: CountingDestination(
            counter: counter,
            label: environment.viewport.name,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey<String>('workbench-desktop-topbar-shell')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('shell-global-search')), findsOneWidget);
      expect(find.byKey(const Key('topbar-settings-button')), findsOneWidget);
      expect(find.byKey(const Key('topbar-agents-icon')), findsOneWidget);
      expect(counter.builds, 1);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('top-bar actions select Agents and Settings destinations', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1100, 760);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final selected = <ClientSection>[];

    await tester.pumpWidget(
      WorkbenchDesktopShellHarness(
        environment: workbenchDesktopEnvironment(width: 1100),
        activeDestination: ClientSection.agents,
        destination: const SizedBox(),
        onSelectDestination: selected.add,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('topbar-agents-icon')));
    await tester.pump();
    expect(selected, [ClientSection.agents]);

    selected.clear();
    await tester.tap(find.byKey(const Key('topbar-settings-button')));
    await tester.pump();
    expect(selected, [ClientSection.settings]);
  });

  testWidgets('large text remains bounded under top-bar chrome', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 820);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final environment = workbenchDesktopEnvironment(
      width: 900,
      height: 820,
      textScale: 2.4,
      reducedMotion: true,
    );

    await tester.pumpWidget(
      WorkbenchDesktopShellHarness(
        environment: environment,
        destination: const Center(child: Text('Scaled destination')),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const ValueKey<String>('workbench-desktop-topbar-shell')),
      findsOneWidget,
    );
    expect(find.text('Scaled destination'), findsOneWidget);
  });

  testWidgets('shell constructs only the destination passed by its host', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 720);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final counter = DestinationBuildCounter();

    await tester.pumpWidget(
      WorkbenchDesktopShellHarness(
        environment: workbenchDesktopEnvironment(width: 900),
        destination: CountingDestination(
          counter: counter,
          label: 'Only active destination',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(counter.builds, 1);
    expect(find.byKey(const Key('passed-destination')), findsOneWidget);
  });

  testWidgets('private chrome consumes semantic status and pairing', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1100, 760);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final chrome = _WorkbenchChromeFake(
      const LayoutChromeSnapshot(
        status: LayoutChromeStatusSnapshot(
          message: 'Ready',
          caption: 'Workbench client',
        ),
      ),
    );
    addTearDown(chrome.dispose);

    await tester.pumpWidget(
      WorkbenchDesktopShellHarness(
        environment: workbenchDesktopEnvironment(width: 1100),
        activeDestination: ClientSection.agents,
        destination: const SizedBox(),
        chrome: chrome,
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('shell-status-text:Ready')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('topbar-pairing-button')));
    await tester.pump();
    expect(chrome.pairingRequests, 1);

    chrome.snapshot = const LayoutChromeSnapshot(
      status: LayoutChromeStatusSnapshot(
        message: 'Updated',
        caption: 'Workbench client',
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('shell-status-text:Updated')),
      findsOneWidget,
    );
  });
}

final class _WorkbenchChromeFake extends ChangeNotifier
    implements LayoutChromePort {
  _WorkbenchChromeFake(this._snapshot);

  LayoutChromeSnapshot _snapshot;
  int pairingRequests = 0;

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
  Future<void> openPairing(BuildContext context) async {
    pairingRequests += 1;
  }
}
