import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/frontend/layout/layout_chrome_port.dart';

import './workbench_desktop_test_harness.dart';

void main() {
  testWidgets('status leaf reacts only to semantic chrome snapshots', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 720);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final chrome = _StatusChromeFake('Ready');
    addTearDown(chrome.dispose);

    await tester.pumpWidget(
      WorkbenchDesktopShellHarness(
        environment: workbenchDesktopEnvironment(width: 1000),
        destination: const SizedBox(),
        chrome: chrome,
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('shell-status-text:Ready')),
      findsOneWidget,
    );

    chrome.setMessage('Updated');
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('shell-status-text:Updated')),
      findsOneWidget,
    );
  });
}

final class _StatusChromeFake extends ChangeNotifier
    implements LayoutChromePort {
  _StatusChromeFake(String message) : _message = message;

  String _message;

  @override
  LayoutChromeSnapshot get value => LayoutChromeSnapshot(
    status: LayoutChromeStatusSnapshot(message: _message, caption: ''),
  );

  void setMessage(String value) {
    _message = value;
    notifyListeners();
  }

  @override
  Future<void> openPairing(BuildContext context) async {}

  @override
  Future<void> openGlobalSearch(BuildContext context) async {}
}
