import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/desktop_app_catalog.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/dock/desktop_dock_model.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/tokens/desktop_desktop_tokens.dart';

import 'desktop_desktop_test_harness.dart';

void main() {
  late DesktopDesktopHarness harness;
  late DesktopDockModel dockModel;

  setUp(() {
    harness = DesktopDesktopHarness();
    dockModel = buildDesktopTestDockModel();
    if (!dockModel.ready) {
      dockModel.debugSeed(const []);
    }
  });

  Future<void> pumpShell(
    WidgetTester tester, {
    ClientSection activeDestination = ClientSection.agents,
    Size size = const Size(1280, 800),
  }) => pumpDesktopShell(
    tester,
    harness: harness,
    dockModel: dockModel,
    activeDestination: activeDestination,
    size: size,
  );

  testWidgets('shell mounts the split workspace with the bottom bar', (
    tester,
  ) async {
    await pumpShell(tester);

    expect(find.byKey(const Key('desktop-desktop-shell')), findsOneWidget);
    expect(find.byKey(const Key('desktop-window-veil')), findsOneWidget);
    expect(find.byKey(const Key('desktop-main-area')), findsOneWidget);
    expect(find.byKey(const Key('desktop-left-pane')), findsOneWidget);
    expect(find.byKey(const Key('desktop-conversation-pane')), findsOneWidget);
    expect(find.byKey(const Key('desktop-dock-bar')), findsOneWidget);
    expect(find.byKey(const Key('desktop-dock-pin-settings')), findsOneWidget);
    expect(find.byKey(const Key('desktop-dock-pin-features')), findsOneWidget);
    expect(find.byKey(const Key('desktop-dock-composer')), findsOneWidget);
    expect(find.byKey(const Key('fixture-dock-composer')), findsOneWidget);
    expect(find.byKey(const Key('desktop-chrome-toggle')), findsOneWidget);
    expect(
      find.byKey(const Key('desktop-main-traffic-light-anchor')),
      findsOneWidget,
    );
    // Default: the features grid on the left, the conversation on the right.
    expect(find.byKey(const Key('desktop-features-grid')), findsOneWidget);
    expect(
      find.byKey(const Key('desktop-fake-content-agents')),
      findsOneWidget,
    );
  });

  testWidgets('dock bar spans the full window width', (tester) async {
    await pumpShell(tester);

    final bar = tester.getRect(find.byKey(const Key('desktop-dock-bar')));
    expect(bar.left, DesktopDesktopMetrics.windowInset);
    expect(1280 - bar.right, DesktopDesktopMetrics.windowInset);
  });

  testWidgets('dock icons stay vertically centered with the active dot '
      'overlaid', (tester) async {
    dockModel.openApp(DesktopAppId.monitoring);
    await pumpShell(tester);

    final strip = tester.getRect(find.byKey(const Key('desktop-dock-bar')));
    final icon = tester.getRect(
      find.byKey(const Key('desktop-dock-pin-settings')),
    );
    // The 44pt tile is centered in the 64pt strip; the active dot overlays
    // the tile's bottom edge instead of pushing the tile up.
    expect(
      (icon.top + icon.bottom) / 2,
      moreOrLessEquals(
        strip.top + DesktopDesktopMetrics.dockBarHeight / 2,
        epsilon: 0.5,
      ),
    );
    expect(icon.height, DesktopDesktopMetrics.dockIconExtent);
  });

  testWidgets('settings pin opens settings in the left pane', (tester) async {
    await pumpShell(tester);
    await tester.tap(find.byKey(const Key('desktop-dock-pin-settings')));
    await tester.pump();
    expect(harness.selections, [ClientSection.settings]);

    // The host delivers the settings destination; the left pane shows it.
    await pumpShell(tester, activeDestination: ClientSection.settings);
    expect(find.byKey(const Key('desktop-settings-app')), findsOneWidget);
    expect(
      find.byKey(const Key('desktop-fake-content-settings')),
      findsOneWidget,
    );
    // The conversation stays mounted on the right.
    expect(
      find.byKey(const Key('desktop-fake-content-agents')),
      findsOneWidget,
    );
  });

  testWidgets('features pin shows the grid and launching an app opens it in '
      'the left pane', (tester) async {
    await pumpShell(tester);

    await tester.tap(find.byKey(const Key('desktop-launchpad-app-monitoring')));
    await tester.pump();
    await tester.pump();

    expect(dockModel.isOpen(DesktopAppId.monitoring), isTrue);
    expect(harness.selections, [ClientSection.monitoring]);

    await pumpShell(tester, activeDestination: ClientSection.monitoring);
    expect(
      find.byKey(const Key('desktop-fake-content-monitoring')),
      findsOneWidget,
    );
    // The dock entry exists and the strip shows it.
    expect(
      find.byKey(const Key('desktop-dock-entry-app:monitoring')),
      findsOneWidget,
    );
  });

  testWidgets('collapse toggle hides the left pane and locks the strip to '
      'the snapped list width', (tester) async {
    dockModel.openApp(DesktopAppId.monitoring);
    await pumpShell(tester);

    final openStrip = tester.getSize(find.byKey(const Key('desktop-dock-bar')));
    expect(openStrip.width, greaterThan(0));

    await tester.tap(find.byKey(const Key('desktop-chrome-toggle')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();

    // Left pane viewport collapsed to zero width; the content stays mounted.
    final viewport = tester.getRect(
      find.byKey(const Key('desktop-left-pane-viewport')),
    );
    expect(viewport.width, 0);
    expect(find.byKey(const Key('desktop-left-pane')), findsOneWidget);

    // The icon strip locks to the snapped 4-slot width, matching the
    // conversation list extent token grid.
    final stripBox = tester.getRect(
      find.descendant(
        of: find.byKey(const Key('desktop-dock-bar')),
        matching: find.byKey(const Key('desktop-dock-pin-features')),
      ),
    );
    expect(stripBox.left, DesktopDesktopMetrics.windowInset + 10 + 44 + 8);
  });

  testWidgets('collapsed icon strip locks to the snapped 4-slot extent', (
    tester,
  ) async {
    await pumpShell(tester);

    await tester.tap(find.byKey(const Key('desktop-chrome-toggle')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();

    // The composer box starts exactly one region gap after the strip; the
    // strip's width is therefore the snapped 4-slot extent (220).
    final snapped = DesktopDesktopMetrics.dockIconSlotsExtent(
      DesktopDesktopMetrics.dockMinIconSlots,
    );
    final composerLeft = tester
        .getRect(find.byKey(const Key('desktop-dock-composer')))
        .left;
    expect(
      composerLeft -
          DesktopDesktopMetrics.windowInset -
          DesktopDesktopMetrics.regionGap,
      moreOrLessEquals(snapped, epsilon: 0.5),
    );
    expect(snapped, 220);
  });

  testWidgets('split handle drags the left pane width', (tester) async {
    await pumpShell(tester);

    final before = tester.getRect(find.byKey(const Key('desktop-left-pane')));
    await tester.drag(
      find.byKey(const Key('desktop-split-handle')),
      const Offset(80, 0),
    );
    await tester.pump();
    final after = tester.getRect(find.byKey(const Key('desktop-left-pane')));
    expect(after.width, greaterThan(before.width));
  });

  testWidgets('reopening settings after collapse expands the pane again', (
    tester,
  ) async {
    await pumpShell(tester, activeDestination: ClientSection.settings);
    await tester.tap(find.byKey(const Key('desktop-chrome-toggle')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(find.byKey(const Key('desktop-dock-pin-settings')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();

    final left = tester.getRect(
      find.byKey(const Key('desktop-left-pane-viewport')),
    );
    expect(left.width, greaterThan(0));
    expect(find.byKey(const Key('desktop-settings-app')), findsOneWidget);
  });

  testWidgets('launching an app dismisses the hovered dock tooltip instead '
      'of leaving it over the opened pane', (tester) async {
    dockModel.openApp(DesktopAppId.monitoring);
    await pumpShell(tester);

    // Hover the dock entry until its tooltip is showing.
    final entry = find.byKey(const Key('desktop-dock-entry-app:monitoring'));
    final hover = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await hover.moveTo(tester.getCenter(entry));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    final label = desktopAppLabel(
      LicoStrings.of(tester.element(entry)),
      DesktopAppId.monitoring,
    );
    expect(
      find.ancestor(of: find.text(label), matching: find.byType(Tooltip)),
      findsWidgets,
    );

    await tester.tap(entry);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.ancestor(of: find.text(label), matching: find.byType(Tooltip)),
      findsNothing,
    );
    await hover.removePointer();
  });
}
