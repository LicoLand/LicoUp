import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/presentation/layout_state_namespace.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_state_port.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/desktop_app_catalog.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/dock/desktop_dock_model.dart';
import 'package:licoup/src/frontend/shared/ui/lico_toast.dart';

import 'desktop_desktop_test_harness.dart';

void main() {
  late DesktopDesktopHarness harness;
  late DesktopDockModel dockModel;

  setUp(() {
    harness = DesktopDesktopHarness();
    dockModel = buildDesktopTestDockModel();
  });

  Future<void> pumpShell(
    WidgetTester tester, {
    ClientSection activeDestination = ClientSection.agents,
  }) async {
    if (!dockModel.ready) {
      dockModel.debugSeed(const []);
    }
    await pumpDesktopShell(
      tester,
      harness: harness,
      dockModel: dockModel,
      activeDestination: activeDestination,
    );
  }

  Finder stackUnderShell() => find.descendant(
    of: find.byKey(const ValueKey<String>('desktop-desktop-shell')),
    matching: find.byType(Stack),
  );

  testWidgets('main area and floating capsule bar render as one screen', (
    tester,
  ) async {
    await pumpShell(tester);

    expect(find.byKey(const Key('desktop-main-area')), findsOneWidget);
    expect(find.byKey(const Key('desktop-dock-bar')), findsOneWidget);
    expect(find.byKey(const Key('desktop-dock-input')), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('desktop-desktop-shell')),
      findsOneWidget,
    );
    // The toast host and notices listener mount near the shell root.
    expect(find.byType(LicoToastHost), findsOneWidget);
    expect(find.byType(LicoToastNoticesListener), findsOneWidget);
  });

  testWidgets('设置 and 功能 are pinned leftmost in order', (tester) async {
    await pumpShell(tester);

    final settings = tester.getTopLeft(
      find.byKey(const Key('desktop-dock-pin-settings')),
    );
    final features = tester.getTopLeft(
      find.byKey(const Key('desktop-dock-pin-features')),
    );
    expect(settings.dx, lessThan(features.dx));

    dockModel.openApp(DesktopAppId.monitoring);
    await tester.pump();
    final entry = tester.getTopLeft(
      find.byKey(const Key('desktop-dock-entry-app:monitoring')),
    );
    expect(entry.dx, greaterThan(features.dx));
  });

  testWidgets('opening 统计面板 from the app store adds its dock icon', (
    tester,
  ) async {
    await pumpShell(tester);

    await tester.tap(find.byKey(const Key('desktop-dock-pin-features')));
    await tester.pump();
    expect(find.byKey(const Key('desktop-launchpad')), findsOneWidget);
    expect(
      find.byKey(const Key('desktop-launchpad-plugin-slot')),
      findsOneWidget,
    );
    for (final app in desktopLaunchpadBuiltinApps) {
      expect(
        find.byKey(Key('desktop-launchpad-app-${app.name}')),
        findsOneWidget,
      );
    }

    await tester.tap(find.byKey(const Key('desktop-launchpad-app-monitoring')));
    await tester.pump();

    expect(find.byKey(const Key('desktop-launchpad')), findsNothing);
    expect(
      find.byKey(const Key('desktop-dock-entry-app:monitoring')),
      findsOneWidget,
    );
    expect(dockModel.isOpen(DesktopAppId.monitoring), isTrue);
    expect(
      find.byKey(const Key('desktop-floating-card-monitoring')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('desktop-fake-content-monitoring')),
      findsOneWidget,
    );
  });

  testWidgets('floating apps render one Z-level above the main area', (
    tester,
  ) async {
    await pumpShell(tester);
    await tester.tap(find.byKey(const Key('desktop-dock-pin-features')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('desktop-launchpad-app-monitoring')));
    await tester.pump();

    final stack = tester.widget<Stack>(stackUnderShell().first);
    final mainIndex = stack.children.indexWhere(
      (child) =>
          child is Positioned &&
          child.child.key == const Key('desktop-main-area'),
    );
    final cardIndex = stack.children.indexWhere(
      (child) =>
          child.key == const ValueKey<String>(
            'desktop-floating-card-monitoring',
          ),
    );
    final barIndex = stack.children.indexWhere(
      (child) =>
          child is Positioned &&
          find
              .descendant(
                of: find.byWidget(child),
                matching: find.byKey(const Key('desktop-dock-bar')),
              )
              .evaluate()
              .isNotEmpty,
    );
    expect(mainIndex, greaterThanOrEqualTo(0));
    expect(cardIndex, greaterThan(mainIndex));
    expect(barIndex, greaterThan(cardIndex));
  });

  testWidgets('closing an app removes its dock icon and card', (tester) async {
    await pumpShell(tester);
    await tester.tap(find.byKey(const Key('desktop-dock-pin-features')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('desktop-launchpad-app-monitoring')));
    await tester.pump();

    await tester.tap(
      find.byKey(const Key('desktop-floating-card-close-monitoring')),
    );
    await tester.pump();

    expect(
      find.byKey(const Key('desktop-floating-card-monitoring')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('desktop-dock-entry-app:monitoring')),
      findsNothing,
    );
    expect(dockModel.isOpen(DesktopAppId.monitoring), isFalse);
  });

  testWidgets(
    'floating card drag clamps while accumulating so reverse drags move at once',
    (tester) async {
      await pumpShell(tester);
      await tester.tap(find.byKey(const Key('desktop-dock-pin-features')));
      await tester.pump();
      await tester.tap(
        find.byKey(const Key('desktop-launchpad-app-monitoring')),
      );
      await tester.pump();

      final card = find.byKey(const Key('desktop-floating-card-monitoring'));
      final header = find.byKey(
        const Key('desktop-floating-card-header-monitoring'),
      );

      final gesture = await tester.startGesture(
        tester.getCenter(header),
      );
      for (var i = 0; i < 20; i++) {
        await gesture.moveBy(const Offset(0, 40));
        await tester.pump();
      }
      final clampedTop = tester.getRect(card).top;

      await gesture.moveBy(const Offset(0, -20));
      await tester.pump();
      expect(tester.getRect(card).top, lessThan(clampedTop));
      await gesture.up();
    },
  );

  testWidgets('right-clicking a dock entry closes the app', (tester) async {
    await pumpShell(tester);
    await tester.tap(find.byKey(const Key('desktop-dock-pin-features')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('desktop-launchpad-app-monitoring')));
    await tester.pump();
    expect(dockModel.isOpen(DesktopAppId.monitoring), isTrue);

    await tester.tap(
      find.byKey(const Key('desktop-dock-entry-app:monitoring')),
      buttons: kSecondaryButton,
    );
    await tester.pump();

    expect(dockModel.isOpen(DesktopAppId.monitoring), isFalse);
    expect(
      find.byKey(const Key('desktop-dock-entry-app:monitoring')),
      findsNothing,
    );
  });

  testWidgets('dock icons reorder by long-press drag across gap targets', (
    tester,
  ) async {
    dockModel.debugSeed(const []);
    dockModel
      ..openApp(DesktopAppId.monitoring)
      ..openApp(DesktopAppId.skillHub);
    await pumpShell(tester);

    expect(
      dockModel.entries.map((entry) => entry.storageId).toList(),
      ['app:monitoring', 'app:skillHub', 'app:conversation'],
    );

    final start = tester.getCenter(
      find.byKey(const Key('desktop-dock-entry-app:skillHub')),
    );
    final gap = tester.getCenter(find.byKey(const Key('desktop-dock-gap-0')));
    final gesture = await tester.startGesture(
      start,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    await gesture.moveTo(gap);
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.up();
    await tester.pump();

    expect(
      dockModel.entries.map((entry) => entry.storageId).toList(),
      ['app:skillHub', 'app:monitoring', 'app:conversation'],
    );
  });

  testWidgets('dropping one icon on another creates an openable folder', (
    tester,
  ) async {
    dockModel.debugSeed(const []);
    dockModel
      ..openApp(DesktopAppId.monitoring)
      ..openApp(DesktopAppId.skillHub);
    await pumpShell(tester);

    final start = tester.getCenter(
      find.byKey(const Key('desktop-dock-entry-app:skillHub')),
    );
    final target = tester.getCenter(
      find.byKey(const Key('desktop-dock-entry-app:monitoring')),
    );
    final gesture = await tester.startGesture(
      start,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    await gesture.moveTo(target);
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.up();
    await tester.pump();

    expect(dockModel.entries, hasLength(2));
    final folder =
        dockModel.entries.first as DesktopDockFolderEntry;
    expect(folder.children, [
      DesktopAppId.monitoring,
      DesktopAppId.skillHub,
    ]);
    expect(
      (dockModel.entries.last as DesktopDockAppEntry).app,
      DesktopAppId.conversation,
    );
    expect(
      find.byKey(Key('desktop-dock-entry-${folder.storageId}')),
      findsOneWidget,
    );

    // The folder opens to show its contained icons; tapping one launches it.
    await tester.tap(
      find.byKey(Key('desktop-dock-entry-${folder.storageId}')),
    );
    await tester.pump();
    expect(find.byKey(const Key('desktop-folder-popup')), findsOneWidget);
    expect(
      find.byKey(const Key('desktop-folder-child-monitoring')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('desktop-folder-child-skillHub')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('desktop-folder-child-skillHub')));
    await tester.pump();
    expect(find.byKey(const Key('desktop-folder-popup')), findsNothing);
    expect(
      find.byKey(const Key('desktop-floating-card-skillHub')),
      findsOneWidget,
    );
  });

  testWidgets('the capsule bar stretches with the entry count', (tester) async {
    await pumpShell(tester);
    // One auto-added 对话 entry: 485 fixed + one entry slot + drop zone.
    expect(
      tester.getSize(find.byKey(const Key('desktop-dock-bar'))).width,
      485 + 52 + 14,
    );

    for (final app in desktopFloatingApps) {
      dockModel.openApp(app);
    }
    await tester.pump();
    // 485 fixed + 8 entry slots + trailing drop zone.
    expect(
      tester.getSize(find.byKey(const Key('desktop-dock-bar'))).width,
      485 + 8 * 52 + 14,
    );
  });

  testWidgets('对话 button left of the input activates the conversation app', (
    tester,
  ) async {
    await pumpShell(tester, activeDestination: ClientSection.settings);
    expect(
      find.byKey(const Key('desktop-dock-input-conversation')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('desktop-dock-input-conversation')));
    await tester.pump();
    expect(harness.selections, [ClientSection.agents]);
  });

  testWidgets('capsule input is a composer on 对话 and search otherwise', (
    tester,
  ) async {
    await pumpShell(tester);
    expect(
      find.byKey(const Key('desktop-dock-input-composer')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('fixture-dock-composer')), findsOneWidget);
    expect(find.byKey(const Key('desktop-dock-input-search')), findsNothing);

    await tester.tap(find.byKey(const Key('desktop-dock-pin-settings')));
    await tester.pump();
    expect(harness.selections, [ClientSection.settings]);
  });

  testWidgets('search capsule opens the global search palette', (
    tester,
  ) async {
    await pumpShell(tester, activeDestination: ClientSection.settings);
    expect(find.byKey(const Key('desktop-dock-input-search')), findsOneWidget);
    expect(find.byKey(const Key('desktop-dock-input-composer')), findsNothing);

    await tester.tap(find.byKey(const Key('desktop-dock-input-search')));
    await tester.pump();
    expect(harness.searchOpens, 1);
  });

  testWidgets('对话 entry appears in the dock while conversation is active', (
    tester,
  ) async {
    await pumpShell(tester);
    expect(dockModel.isOpen(DesktopAppId.conversation), isTrue);
    expect(
      find.byKey(const Key('desktop-dock-entry-app:conversation')),
      findsOneWidget,
    );
  });

  testWidgets('launchpad 对话 launches the conversation fullscreen app', (
    tester,
  ) async {
    await pumpShell(tester, activeDestination: ClientSection.settings);
    await tester.tap(find.byKey(const Key('desktop-dock-pin-features')));
    await tester.pump();
    await tester.tap(
      find.byKey(const Key('desktop-launchpad-app-conversation')),
    );
    await tester.pump();
    expect(harness.selections, [ClientSection.agents]);
  });

  testWidgets('settings opens fullscreen with its own left card and lights', (
    tester,
  ) async {
    await pumpShell(tester, activeDestination: ClientSection.settings);

    expect(find.byKey(const Key('desktop-settings-app')), findsOneWidget);
    expect(
      find.byKey(const Key('desktop-settings-nav-card')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('desktop-settings-traffic-light-row')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('desktop-settings-section-list')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('desktop-settings-main')), findsOneWidget);
    expect(
      find.byKey(const Key('desktop-fake-content-settings')),
      findsOneWidget,
    );
    // The main-area anchor yields to the settings card anchor.
    expect(
      find.byKey(const Key('desktop-main-traffic-light-anchor')),
      findsNothing,
    );

    final card = tester.getTopLeft(
      find.byKey(const Key('desktop-settings-nav-card')),
    );
    final lights = tester.getTopLeft(
      find.byKey(const Key('desktop-settings-traffic-light-row')),
    );
    final main = tester.getTopLeft(
      find.byKey(const Key('desktop-settings-main')),
    );
    expect(lights.dx, lessThan(main.dx));
    expect(lights.dy - card.dy, lessThan(20));
  });

  testWidgets('settings section rows drive the shared section channel', (
    tester,
  ) async {
    await pumpShell(tester, activeDestination: ClientSection.settings);

    await tester.tap(find.byKey(const Key('desktop-settings-section-storage')));
    await tester.pump();

    final tab = harness.scopedState?.readIfDeclared(
      LayoutStateChannels.settingsSection,
    );
    expect(tab, isA<LayoutTabState>());
    expect((tab! as LayoutTabState).index, 5);
  });

  testWidgets('models pane apps host the models destination in a card', (
    tester,
  ) async {
    await pumpShell(tester);
    await tester.tap(find.byKey(const Key('desktop-dock-pin-features')));
    await tester.pump();
    await tester.tap(
      find.byKey(const Key('desktop-launchpad-app-modelsChatChannels')),
    );
    await tester.pump();

    expect(
      find.byKey(const Key('desktop-floating-card-modelsChatChannels')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('desktop-fake-content-models')),
      findsOneWidget,
    );
  });
}
