import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/presentation/semantic_destination.dart';

import './workbench_desktop_test_harness.dart';

void main() {
  testWidgets('search resolves a section alias and submits one destination', (
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
        destination: const SizedBox(),
        onSelectDestination: selected.add,
      ),
    );
    await tester.pumpAndSettle();

    final field = find.descendant(
      of: find.byKey(const Key('shell-global-search')),
      matching: find.byType(TextField),
    );
    await tester.enterText(field, 'preference');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(selected, [ClientSection.settings]);
    expect(tester.takeException(), isNull);
  });
}
