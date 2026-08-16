import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

import './dashboard_desktop_test_harness.dart';

void main() {
  testWidgets('medium and expanded variants host the notes three-pane chrome', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    for (final size in const [Size(900, 720), Size(1280, 800)]) {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      final environment = dashboardDesktopEnvironment(
        width: size.width,
        height: size.height,
      );
      final counter = DestinationBuildCounter();

      await tester.pumpWidget(
        DashboardDesktopShellHarness(
          environment: environment,
          destination: CountingDestination(
            counter: counter,
            label: environment.viewport.name,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey<String>('dashboard-desktop-notes-shell')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('dashboard-folder-sidebar')), findsOneWidget);
      expect(find.byKey(const Key('shell-global-search')), findsOneWidget);
      for (final section in ClientSection.values) {
        expect(
          find.byKey(Key('dashboard-folder-nav-${section.name}')),
          findsOneWidget,
          reason: '${section.name} keeps a folder row',
        );
      }
      // The retired top-bar and status-bar chrome is gone for good.
      expect(find.byKey(const Key('topbar-settings-button')), findsNothing);
      expect(find.byKey(const Key('topbar-agents-icon')), findsNothing);
      expect(find.byKey(const Key('topbar-pairing-button')), findsNothing);
      expect(counter.builds, 1);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('folder sidebar resizes by dragging its trailing edge', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1100, 760);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      DashboardDesktopShellHarness(
        environment: dashboardDesktopEnvironment(width: 1100),
        activeDestination: ClientSection.agents,
        destination: const SizedBox(),
      ),
    );
    await tester.pumpAndSettle();

    double sidebarWidth() =>
        tester.getRect(find.byKey(const Key('dashboard-folder-sidebar'))).width;
    expect(sidebarWidth(), 180);

    final handle = find.byKey(const Key('dashboard-sidebar-resize-handle'));
    expect(handle, findsOneWidget);
    await tester.drag(handle, const Offset(40, 0));
    await tester.pump();
    expect(sidebarWidth(), 220);

    await tester.drag(handle, const Offset(-400, 0));
    await tester.pump();
    expect(sidebarWidth(), 140);

    await tester.drag(handle, const Offset(400, 0));
    await tester.pump();
    expect(sidebarWidth(), 320);
    expect(tester.takeException(), isNull);
  });

  testWidgets('folder sidebar marks the selection with the house rule', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1100, 760);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      DashboardDesktopShellHarness(
        environment: dashboardDesktopEnvironment(width: 1100),
        activeDestination: ClientSection.agents,
        destination: const SizedBox(),
      ),
    );
    await tester.pump();

    Color? rowColor(ClientSection section) {
      final container = tester.widget<AnimatedContainer>(
        find
            .descendant(
              of: find.byKey(Key('dashboard-folder-nav-${section.name}')),
              matching: find.byType(AnimatedContainer),
            )
            .first,
      );
      return (container.decoration as BoxDecoration?)?.color;
    }

    final shellContext = tester.element(
      find.byKey(const ValueKey<String>('dashboard-desktop-notes-shell')),
    );
    final colors = shellContext.licoColors;
    expect(rowColor(ClientSection.agents), colors.primary);
    expect(rowColor(ClientSection.skillHub), isNot(colors.primary));

    final selectedIcon = tester.widget<Icon>(
      find
          .descendant(
            of: find.byKey(const Key('dashboard-folder-nav-agents')),
            matching: find.byType(Icon),
          )
          .first,
    );
    expect(selectedIcon.color, colors.textOnPrimary);
    expect(tester.takeException(), isNull);
  });

  testWidgets('plugins folder is independent of the skills folder', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1100, 760);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      DashboardDesktopShellHarness(
        environment: dashboardDesktopEnvironment(width: 1100),
        activeDestination: ClientSection.pluginManagement,
        destination: const SizedBox(),
      ),
    );
    await tester.pump();

    Color? rowColor(ClientSection section) {
      final container = tester.widget<AnimatedContainer>(
        find
            .descendant(
              of: find.byKey(Key('dashboard-folder-nav-${section.name}')),
              matching: find.byType(AnimatedContainer),
            )
            .first,
      );
      return (container.decoration as BoxDecoration?)?.color;
    }

    final shellContext = tester.element(
      find.byKey(const ValueKey<String>('dashboard-desktop-notes-shell')),
    );
    final colors = shellContext.licoColors;
    expect(rowColor(ClientSection.pluginManagement), colors.primary);
    expect(rowColor(ClientSection.skillHub), isNot(colors.primary));
    expect(
      find.byKey(const Key('dashboard-folder-nav-pluginManagement')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('folder rows navigate to every destination', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1100, 760);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final selected = <ClientSection>[];

    await tester.pumpWidget(
      DashboardDesktopShellHarness(
        environment: dashboardDesktopEnvironment(width: 1100),
        activeDestination: ClientSection.agents,
        destination: const SizedBox(),
        onSelectDestination: selected.add,
      ),
    );
    await tester.pump();

    for (final section in const [
      ClientSection.skillHub,
      ClientSection.mobileRelay,
      ClientSection.monitoring,
      ClientSection.settings,
      ClientSection.agents,
    ]) {
      await tester.tap(find.byKey(Key('dashboard-folder-nav-${section.name}')));
      await tester.pump();
    }
    expect(selected, [
      ClientSection.skillHub,
      ClientSection.mobileRelay,
      ClientSection.monitoring,
      ClientSection.settings,
      ClientSection.agents,
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('large text remains bounded in the notes composition', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 820);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final environment = dashboardDesktopEnvironment(
      width: 900,
      height: 820,
      textScale: 2.4,
      reducedMotion: true,
    );

    await tester.pumpWidget(
      DashboardDesktopShellHarness(
        environment: environment,
        destination: const Center(child: Text('Scaled destination')),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const ValueKey<String>('dashboard-desktop-notes-shell')),
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
      DashboardDesktopShellHarness(
        environment: dashboardDesktopEnvironment(width: 900),
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
}
