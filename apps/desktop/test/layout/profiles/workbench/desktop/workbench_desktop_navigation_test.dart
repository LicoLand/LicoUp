import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/presentation/semantic_destination.dart';

import './workbench_desktop_test_harness.dart';

void main() {
  testWidgets('navigation exposes the active Agents action independently', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 720);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final selected = <ClientSection>[];

    await tester.pumpWidget(
      WorkbenchDesktopShellHarness(
        environment: workbenchDesktopEnvironment(width: 1000),
        activeDestination: ClientSection.agents,
        destination: const SizedBox(),
        onSelectDestination: selected.add,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('topbar-nav-active-agents')), findsOneWidget);
    await tester.tap(find.byKey(const Key('topbar-agents-icon')));
    await tester.pump();
    expect(selected, [ClientSection.agents]);
  });
}
