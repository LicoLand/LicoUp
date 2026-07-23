import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/layout/layout_chrome_port.dart';

import './workbench_desktop_test_harness.dart';

void main() {
  testWidgets('top bar routes pairing and settings through explicit actions', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1100, 760);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final chrome = _TopBarChromeFake();
    final selected = <ClientSection>[];
    addTearDown(chrome.dispose);

    await tester.pumpWidget(
      WorkbenchDesktopShellHarness(
        environment: workbenchDesktopEnvironment(width: 1100),
        destination: const SizedBox(),
        chrome: chrome,
        onSelectDestination: selected.add,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('topbar-pairing-button')));
    await tester.pump();
    expect(chrome.pairingRequests, 1);

    await tester.tap(find.byKey(const Key('topbar-settings-button')));
    await tester.pump();
    expect(selected, [ClientSection.settings]);
  });
}

final class _TopBarChromeFake extends ChangeNotifier
    implements LayoutChromePort {
  int pairingRequests = 0;

  @override
  LayoutChromeSnapshot get value => const LayoutChromeSnapshot.empty();

  @override
  Future<void> openPairing(BuildContext context) async {
    pairingRequests += 1;
  }

  @override
  Future<void> openGlobalSearch(BuildContext context) async {}
}
