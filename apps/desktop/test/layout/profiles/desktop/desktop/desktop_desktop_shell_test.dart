import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/presentation/desktop_dock_layout.dart';
import 'package:licoup/src/contracts/presentation/layout_state_namespace.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_agents_directive.dart';
import 'package:licoup/src/frontend/layout/layout_chrome_features.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/layout/layout_state_port.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/desktop_app_catalog.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/desktop_desktop_copy.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/dock/desktop_dock_model.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/shell/desktop_traffic_light_anchor.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/tokens/desktop_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/client_platform_ports.dart';
import 'package:licoup/src/frontend/shared/desktop_dock_layout_store.dart';

import 'desktop_desktop_test_harness.dart';
import 'package:licoup/src/frontend/shared/ui/lico_galaxy.dart';
import 'package:licoup/src/frontend/shared/ui/lico_glass_region.dart';
import 'package:licoup/src/frontend/shared/ui/lico_pane_card.dart';

/// Keeps shell tests off the file system: mutations persist in memory.
final class _MemoryDockStore extends DesktopDockLayoutStore {
  @override
  Future<DesktopDockLayoutSnapshot> load(Object portableData) async =>
      const DesktopDockLayoutSnapshot(entries: []);

  @override
  Future<void> save(
    Object portableData,
    DesktopDockLayoutSnapshot snapshot,
  ) async {}
}

/// A store whose load completes only when the test says so.
final class _PendingDockStore extends DesktopDockLayoutStore {
  final Completer<DesktopDockLayoutSnapshot> loaded = Completer();

  @override
  Future<DesktopDockLayoutSnapshot> load(Object portableData) => loaded.future;

  @override
  Future<void> save(
    Object portableData,
    DesktopDockLayoutSnapshot snapshot,
  ) async {}
}

const _sketch = LayoutPluginWindowSummary(
  id: 'sketch',
  name: 'Sketch Board',
  official: true,
  open: false,
);
const _notes = LayoutPluginWindowSummary(
  id: 'notes',
  name: 'Notes',
  official: false,
  open: false,
);

Finder _key(String value) => find.byKey(ValueKey<String>(value));

Finder _entry(DesktopAppId app) => _key('desktop-dock-entry-app:${app.name}');

void main() {
  late DesktopDesktopHarness harness;
  late DesktopDockModel dockModel;

  setUp(() {
    harness = DesktopDesktopHarness();
    dockModel = DesktopDockModel(
      store: _MemoryDockStore(),
      portableData: Object(),
    )..debugSeed(const []);
  });

  Future<void> pumpShell(
    WidgetTester tester, {
    ClientSection activeDestination = ClientSection.agents,
    Size size = const Size(1280, 800),
    bool reducedMotion = false,
  }) => pumpDesktopShell(
    tester,
    harness: harness,
    dockModel: dockModel,
    activeDestination: activeDestination,
    size: size,
    reducedMotion: reducedMotion,
  );

  /// The quick switcher opens from the title-row search button.
  Future<void> openQuickSwitcher(WidgetTester tester) async {
    await tester.tap(_key('desktop-quick-switcher-button'));
    await tester.pump();
  }

  LicoStrings stringsOf(WidgetTester tester) =>
      LicoStrings.of(tester.element(_key('desktop-dock')));

  LayoutPalette paletteOf(WidgetTester tester) =>
      tester.element(_key('desktop-dock')).layoutPalette;

  String titleOf(WidgetTester tester) => tester
      .widget<Text>(_key('desktop-work-area-title'))
      .textSpan!
      .toPlainText();

  Color? dotColor(WidgetTester tester, String itemId) {
    final dot = tester.widget<AnimatedContainer>(
      _key('desktop-dock-dot:$itemId'),
    );
    return (dot.decoration! as BoxDecoration).color;
  }

  double scaleOf(WidgetTester tester, Finder entry) => tester
      .widget<AnimatedScale>(
        find.descendant(of: entry, matching: find.byType(AnimatedScale)),
      )
      .scale;

  LayoutAgentsDirective directiveOf(WidgetTester tester) => tester
      .widget<LayoutAgentsDirectiveScope>(
        find.byType(LayoutAgentsDirectiveScope),
      )
      .directive;

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
  }

  Future<void> openMenu(WidgetTester tester, Finder icon) async {
    await tester.tap(icon, buttons: kSecondaryButton);
    await tester.pump();
    expect(_key('desktop-dock-menu'), findsOneWidget);
  }

  Future<TestGesture> hover(WidgetTester tester, Finder target) async {
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(target));
    await tester.pump();
    return gesture;
  }

  Future<void> longPressDrag(
    WidgetTester tester,
    Finder source,
    Finder target,
  ) async {
    final gesture = await tester.startGesture(tester.getCenter(source));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    await gesture.moveTo(tester.getCenter(target));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await gesture.up();
    await tester.pump();
  }

  group('layout', () {
    testWidgets('mounts the work area, the chat sidebar and the floating '
        'dock, opening on Collaboration', (tester) async {
      await pumpShell(tester);

      expect(_key('desktop-desktop-shell'), findsOneWidget);
      expect(_key('desktop-window-veil'), findsOneWidget);
      expect(_key('desktop-work-area'), findsOneWidget);
      expect(_key('desktop-chat-sidebar'), findsOneWidget);
      expect(_key('desktop-dock'), findsOneWidget);
      expect(_key('desktop-work-area-title-row'), findsOneWidget);
      expect(_key('desktop-main-traffic-light-anchor'), findsOneWidget);
      expect(_key('desktop-quick-switcher-button'), findsOneWidget);

      // Collaboration is the default app; the conversation is the sidebar.
      expect(_key('fixture-collaboration-app'), findsOneWidget);
      expect(_key('desktop-fake-content-agents'), findsOneWidget);
      expect(
        titleOf(tester),
        desktopAppLabel(stringsOf(tester), DesktopAppId.collaboration),
      );
      expect(harness.selections, isEmpty);
    });

    testWidgets('the two cards sit inside the window inset with a 12px '
        'gutter and a 400px sidebar', (tester) async {
      await pumpShell(tester);

      final work = tester.getRect(_key('desktop-work-area'));
      final sidebar = tester.getRect(_key('desktop-chat-sidebar'));
      const inset = DesktopDesktopMetrics.windowInset;
      expect(work.left, inset);
      expect(work.top, inset);
      expect(work.bottom, 800 - inset);
      expect(sidebar.right, 1280 - inset);
      expect(sidebar.top, inset);
      expect(sidebar.width, DesktopDesktopMetrics.sidebarDefaultExtent);
      expect(sidebar.left - work.right, DesktopDesktopMetrics.paneGap);
    });

    testWidgets('the title row clears the traffic lights', (tester) async {
      await pumpShell(tester);

      final row = tester.getRect(_key('desktop-work-area-title-row'));
      expect(row.height, DesktopDesktopMetrics.titleRowExtent);

      final work = tester.getRect(_key('desktop-work-area'));
      final anchor = tester.getRect(_key('desktop-main-traffic-light-anchor'));
      // The band is the title row's leading region: pane left edge, pane
      // top. The row's bottom hairline insets the widget half a pixel; the
      // reported band keeps the full title-row height (asserted in the
      // trailing-edge test). No host reply yet: the fallback width.
      expect(anchor.left, moreOrLessEquals(work.left, epsilon: 0.5));
      expect(anchor.top, moreOrLessEquals(row.top, epsilon: 0.5));
      expect(anchor.height, moreOrLessEquals(row.height - 0.5, epsilon: 0.01));
      expect(anchor.width, DesktopTrafficLightAnchor.fallbackWidth);

      final icon = tester.getRect(_key('desktop-work-area-title-icon'));
      expect(
        icon.left,
        moreOrLessEquals(
          anchor.left + DesktopTrafficLightAnchor.fallbackWidth,
          epsilon: 0.5,
        ),
      );
      expect(
        (icon.top + icon.bottom) / 2,
        moreOrLessEquals((row.top + row.bottom) / 2, epsilon: 0.5),
      );
    });

    testWidgets('the anchor widens around the cluster trailing edge the '
        'host reports', (tester) async {
      Rect? reported;
      final previous = ClientPlatformPorts.reportTrafficLightAnchor;
      ClientPlatformPorts.reportTrafficLightAnchor = (rect) async {
        reported = rect;
        return rect == null
            ? null
            : (leading: rect.left + 8, trailing: rect.left + 76);
      };
      addTearDown(
        () => ClientPlatformPorts.reportTrafficLightAnchor = previous,
      );

      await pumpShell(tester);
      await tester.pump();

      expect(reported, isNotNull);
      expect(reported!.height, DesktopDesktopMetrics.titleRowExtent);
      final anchor = tester.getRect(_key('desktop-main-traffic-light-anchor'));
      expect(
        anchor.width,
        moreOrLessEquals(76 + DesktopTrafficLightAnchor.gapAfter, epsilon: 0.5),
      );
      final icon = tester.getRect(_key('desktop-work-area-title-icon'));
      expect(icon.left, moreOrLessEquals(anchor.right, epsilon: 0.5));
    });

    testWidgets('the title row places the app actions at its right edge', (
      tester,
    ) async {
      await pumpShell(tester);

      final row = tester.getRect(_key('desktop-work-area-title-row'));
      final search = tester.getRect(_key('desktop-quick-switcher-button'));
      expect(search.right, moreOrLessEquals(row.right - 12, epsilon: 0.5));
    });

    testWidgets('the title row places the plugin actions at its right edge', (
      tester,
    ) async {
      harness.features.pluginState.value = const [_sketch];
      await pumpShell(tester);
      await openQuickSwitcher(tester);
      harness.features.quickSwitcherOnOpenApp!('plugin:sketch');
      await tester.pump();

      final row = tester.getRect(_key('desktop-work-area-title-row'));
      final actions = tester.getRect(_key('fixture-plugin-close-sketch'));
      final search = tester.getRect(_key('desktop-quick-switcher-button'));
      expect(search.right, moreOrLessEquals(row.right - 12, epsilon: 0.5));
      expect(actions.right, moreOrLessEquals(search.left - 4, epsilon: 0.5));
    });

    testWidgets('the dock floats centered at the bottom of the work area and '
        'content reserves space above it', (tester) async {
      await pumpShell(tester);

      final work = tester.getRect(_key('desktop-work-area'));
      final dock = tester.getRect(_key('desktop-dock'));
      expect(dock.height, DesktopDesktopMetrics.dockHeight);
      expect(dock.center.dx, moreOrLessEquals(work.center.dx, epsilon: 0.5));
      // Card content starts inside the card's 0.5px hairline.
      expect(
        work.bottom - dock.bottom,
        moreOrLessEquals(DesktopDesktopMetrics.dockBottomInset, epsilon: 0.5),
      );

      final content = tester.getRect(_key('fixture-collaboration-app'));
      expect(
        content.top,
        moreOrLessEquals(
          work.top + DesktopDesktopMetrics.titleRowExtent,
          epsilon: 0.5,
        ),
      );
      expect(
        work.bottom - content.bottom,
        moreOrLessEquals(
          DesktopDesktopMetrics.dockReservedExtent,
          epsilon: 0.5,
        ),
      );
      expect(content.bottom, lessThanOrEqualTo(dock.top));
    });

    testWidgets('a narrow window keeps the work area at its minimum width', (
      tester,
    ) async {
      await pumpShell(tester, size: const Size(800, 700));

      final work = tester.getRect(_key('desktop-work-area'));
      final sidebar = tester.getRect(_key('desktop-chat-sidebar'));
      expect(work.width, DesktopDesktopMetrics.workAreaMinExtent);
      expect(
        sidebar.width,
        800 -
            DesktopDesktopMetrics.windowInset * 2 -
            DesktopDesktopMetrics.paneGap -
            DesktopDesktopMetrics.workAreaMinExtent,
      );
      final dock = tester.getRect(_key('desktop-dock'));
      expect(dock.left, greaterThanOrEqualTo(work.left));
      expect(dock.right, lessThanOrEqualTo(work.right));
    });
  });

  group('dock', () {
    testWidgets('groups the arranged built-in apps before Plugin Center and '
        'Settings', (tester) async {
      await pumpShell(tester);

      final lefts = [
        for (final app in desktopDockApps) tester.getRect(_entry(app)).left,
      ];
      expect(lefts, orderedEquals([...lefts]..sort()));
      final divider = tester.getRect(_key('desktop-dock-divider-system'));
      final center = tester.getRect(_key('desktop-dock-pin-pluginCenter'));
      final settings = tester.getRect(_key('desktop-dock-pin-settings'));
      expect(lefts.last, lessThan(divider.left));
      expect(divider.right, lessThanOrEqualTo(center.left));
      expect(center.right, lessThan(settings.left));
      // No plugin windows: no plugin group and no divider for it.
      expect(_key('desktop-dock-divider-plugins'), findsNothing);
    });

    testWidgets('follows the stored arrangement, including folders', (
      tester,
    ) async {
      dockModel.debugSeed(const [
        DesktopDockAppEntry(DesktopAppId.monitoring),
        DesktopDockFolderEntry(
          id: 'folder-1',
          children: [DesktopAppId.agentHub, DesktopAppId.devices],
        ),
      ]);
      await pumpShell(tester);

      final monitoring = tester.getRect(_entry(DesktopAppId.monitoring));
      final folder = tester.getRect(_key('desktop-dock-entry-folder:folder-1'));
      final collaboration = tester.getRect(_entry(DesktopAppId.collaboration));
      expect(monitoring.left, lessThan(folder.left));
      // The missing apps join after their nearest catalog predecessor.
      expect(collaboration.left, lessThan(monitoring.left));
      expect(_entry(DesktopAppId.agentHub), findsNothing);
    });

    testWidgets('stays hidden until the stored arrangement is applied, so a '
        'restored order never replaces the default on screen', (tester) async {
      final store = _PendingDockStore();
      dockModel = DesktopDockModel(store: store, portableData: Object());
      await pumpShell(tester);

      AnimatedOpacity veil() => tester.widget<AnimatedOpacity>(
        find
            .ancestor(
              of: _key('desktop-dock'),
              matching: find.byType(AnimatedOpacity),
            )
            .first,
      );
      IgnorePointer gate() => tester.widget<IgnorePointer>(
        find
            .ancestor(
              of: _key('desktop-dock'),
              matching: find.byType(IgnorePointer),
            )
            .first,
      );
      expect(dockModel.ready, isFalse);
      expect(veil().opacity, 0);
      expect(gate().ignoring, isTrue);

      store.loaded.complete(
        const DesktopDockLayoutSnapshot(
          entries: [
            DesktopDockStoredAppEntry('monitoring'),
            DesktopDockStoredAppEntry('collaboration'),
          ],
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(dockModel.ready, isTrue);
      expect(veil().opacity, 1);
      expect(gate().ignoring, isFalse);
      expect(
        tester.getRect(_entry(DesktopAppId.monitoring)).left,
        lessThan(tester.getRect(_entry(DesktopAppId.collaboration)).left),
      );
    });

    testWidgets('hover magnifies by transform with a label; neighbours never '
        'move', (tester) async {
      await pumpShell(tester);
      final before = tester.getRect(_entry(DesktopAppId.modelsGateway));

      await hover(tester, _entry(DesktopAppId.monitoring));

      expect(
        scaleOf(tester, _entry(DesktopAppId.monitoring)),
        DesktopDesktopMetrics.dockHoverScale,
      );
      expect(
        scaleOf(tester, _entry(DesktopAppId.agentHub)),
        DesktopDesktopMetrics.dockNeighborScale,
      );
      expect(
        scaleOf(tester, _entry(DesktopAppId.modelsGateway)),
        DesktopDesktopMetrics.dockNeighborScale,
      );
      expect(scaleOf(tester, _entry(DesktopAppId.collaboration)), 1);
      expect(tester.getRect(_entry(DesktopAppId.modelsGateway)), before);
      expect(
        find.descendant(
          of: _key('desktop-dock-label'),
          matching: find.text(
            desktopAppLabel(stringsOf(tester), DesktopAppId.monitoring),
          ),
        ),
        findsOneWidget,
      );
    });

    testWidgets('reduced motion keeps every icon at rest', (tester) async {
      await pumpShell(tester, reducedMotion: true);

      await hover(tester, _entry(DesktopAppId.monitoring));

      for (final app in desktopDockApps) {
        expect(scaleOf(tester, _entry(app)), 1, reason: app.name);
      }
      expect(_key('desktop-dock-label'), findsOneWidget);
    });

    testWidgets('the collaboration badge counts waiting decisions', (
      tester,
    ) async {
      await pumpShell(tester);
      final collaboration = _entry(DesktopAppId.collaboration);
      expect(
        find.descendant(of: collaboration, matching: find.text('3')),
        findsNothing,
      );

      harness.features.collaborationState.value =
          const LayoutCollaborationAppState(
            subtitle: 'Release plan',
            pendingDecisions: 3,
          );
      await tester.pump();

      expect(
        find.descendant(of: collaboration, matching: find.text('3')),
        findsOneWidget,
      );
      expect(
        titleOf(tester),
        '${desktopAppLabel(stringsOf(tester), DesktopAppId.collaboration)}'
        ' · Release plan',
      );

      harness.features.collaborationState.value =
          const LayoutCollaborationAppState(pendingDecisions: 12);
      await tester.pump();
      expect(
        find.descendant(of: collaboration, matching: find.text('9+')),
        findsOneWidget,
      );
    });

    testWidgets('dragging an icon onto a gap reorders the dock', (
      tester,
    ) async {
      await pumpShell(tester);

      await longPressDrag(
        tester,
        _entry(DesktopAppId.monitoring),
        _key('desktop-dock-gap-0'),
      );

      expect(dockModel.entries.first, isA<DesktopDockAppEntry>());
      expect(
        (dockModel.entries.first as DesktopDockAppEntry).app,
        DesktopAppId.monitoring,
      );
      expect(
        tester.getRect(_entry(DesktopAppId.monitoring)).left,
        lessThan(tester.getRect(_entry(DesktopAppId.collaboration)).left),
      );
    });

    testWidgets('dropping an icon onto another makes a folder', (tester) async {
      await pumpShell(tester);

      await longPressDrag(
        tester,
        _entry(DesktopAppId.monitoring),
        _entry(DesktopAppId.modelsGateway),
      );

      final folder = dockModel.entries
          .whereType<DesktopDockFolderEntry>()
          .single;
      expect(folder.children, [
        DesktopAppId.modelsGateway,
        DesktopAppId.monitoring,
      ]);
      expect(_key('desktop-dock-entry-${folder.storageId}'), findsOneWidget);
    });

    testWidgets('a folder opens above the dock; its apps open and drag back '
        'out', (tester) async {
      dockModel.debugSeed(const [
        DesktopDockAppEntry(DesktopAppId.collaboration),
        DesktopDockFolderEntry(
          id: 'folder-1',
          children: [DesktopAppId.agentHub, DesktopAppId.devices],
        ),
      ]);
      await pumpShell(tester);

      await tester.tap(_key('desktop-dock-entry-folder:folder-1'));
      await tester.pump();
      final popup = tester.getRect(_key('desktop-folder-popup'));
      expect(
        popup.bottom,
        lessThanOrEqualTo(tester.getRect(_key('desktop-dock')).top),
      );

      await tester.tap(_key('desktop-folder-child-agentHub'));
      await tester.pump();
      expect(harness.selections, [ClientSection.agentHub]);
      expect(_key('desktop-folder-popup'), findsNothing);

      await tester.tap(_key('desktop-dock-entry-folder:folder-1'));
      await tester.pump();
      await longPressDrag(
        tester,
        _key('desktop-folder-child-devices'),
        _key('desktop-dock-gap-0'),
      );

      // The folder dissolved around its last remaining app.
      expect(dockModel.entries.whereType<DesktopDockFolderEntry>(), isEmpty);
      expect(
        (dockModel.entries.first as DesktopDockAppEntry).app,
        DesktopAppId.devices,
      );
    });
  });

  group('apps', () {
    testWidgets('opening a dock app selects its destination and keeps the '
        'previous app mounted offstage', (tester) async {
      await pumpShell(tester);

      await tester.tap(_entry(DesktopAppId.monitoring));
      await tester.pump();
      expect(harness.selections, [ClientSection.monitoring]);
      // The work area keeps its current app until the host delivers.
      expect(_key('fixture-collaboration-app'), findsOneWidget);

      await pumpShell(tester, activeDestination: ClientSection.monitoring);
      expect(_key('desktop-fake-content-monitoring'), findsOneWidget);
      expect(_key('fixture-collaboration-app'), findsNothing);
      expect(
        find.byKey(
          const ValueKey<String>('fixture-collaboration-app'),
          skipOffstage: false,
        ),
        findsOneWidget,
      );
      expect(harness.features.collaborationBuilds, greaterThan(0));
      expect(
        titleOf(tester),
        desktopAppLabel(stringsOf(tester), DesktopAppId.monitoring),
      );
      // The conversation never leaves the sidebar.
      expect(_key('desktop-fake-content-agents'), findsOneWidget);

      final palette = paletteOf(tester);
      expect(dotColor(tester, 'app:monitoring'), palette.primary);
      final collaborationDot = dotColor(tester, 'app:collaboration');
      expect(collaborationDot, isNot(palette.primary));
      expect(collaborationDot, isNot(Colors.transparent));
      expect(dotColor(tester, 'app:agentHub'), Colors.transparent);
    });

    testWidgets('quitting the active app falls back to Collaboration', (
      tester,
    ) async {
      await pumpShell(tester);
      await tester.tap(_entry(DesktopAppId.monitoring));
      await tester.pump();
      await pumpShell(tester, activeDestination: ClientSection.monitoring);

      await openMenu(tester, _entry(DesktopAppId.monitoring));
      expect(_key('desktop-dock-menu-open'), findsOneWidget);
      await tester.tap(_key('desktop-dock-menu-quit'));
      await tester.pump();

      expect(harness.selections, [
        ClientSection.monitoring,
        ClientSection.agents,
      ]);
      await pumpShell(tester);
      expect(_key('fixture-collaboration-app'), findsOneWidget);
      expect(
        find.byKey(
          const ValueKey<String>('desktop-work-slot-monitoring'),
          skipOffstage: false,
        ),
        findsNothing,
      );
      expect(dotColor(tester, 'app:monitoring'), Colors.transparent);
    });

    testWidgets('Collaboration cannot quit and the menu dismisses outside', (
      tester,
    ) async {
      await pumpShell(tester);

      await openMenu(tester, _entry(DesktopAppId.collaboration));
      expect(_key('desktop-dock-menu-open'), findsOneWidget);
      expect(_key('desktop-dock-menu-quit'), findsNothing);

      await tester.tapAt(const Offset(300, 200));
      await tester.pump();
      expect(_key('desktop-dock-menu'), findsNothing);
    });

    testWidgets('Escape dismisses the dock menu', (tester) async {
      await pumpShell(tester);
      await openMenu(tester, _entry(DesktopAppId.collaboration));

      Focus.of(tester.element(_key('desktop-work-area'))).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      expect(_key('desktop-dock-menu'), findsNothing);
    });

    testWidgets('Settings and Plugin Center pins open their destinations', (
      tester,
    ) async {
      await pumpShell(tester);

      await tester.tap(_key('desktop-dock-pin-settings'));
      await tester.pump();
      await tester.tap(_key('desktop-dock-pin-pluginCenter'));
      await tester.pump();
      expect(harness.selections, [
        ClientSection.settings,
        ClientSection.pluginManagement,
      ]);
    });

    testWidgets('external navigation claims the work area; the conversation '
        'destination keeps the current app', (tester) async {
      await pumpShell(tester);

      await pumpShell(tester, activeDestination: ClientSection.settings);
      expect(_key('desktop-settings-app'), findsOneWidget);
      expect(_key('desktop-fake-content-settings'), findsOneWidget);
      expect(dotColor(tester, 'app:settings'), paletteOf(tester).primary);

      await pumpShell(tester);
      expect(_key('desktop-fake-content-settings'), findsOneWidget);
      expect(
        titleOf(tester),
        desktopAppLabel(stringsOf(tester), DesktopAppId.settings),
      );
      expect(harness.selections, isEmpty);
    });

    testWidgets('apps outside the dock join it only while running', (
      tester,
    ) async {
      await pumpShell(tester);
      expect(_key('desktop-dock-running-app:skillHub'), findsNothing);

      await pumpShell(tester, activeDestination: ClientSection.skillHub);
      expect(_key('desktop-fake-content-skillHub'), findsOneWidget);
      final running = _key('desktop-dock-running-app:skillHub');
      expect(running, findsOneWidget);
      expect(
        tester.getRect(running).right,
        lessThanOrEqualTo(
          tester.getRect(_key('desktop-dock-divider-system')).left,
        ),
      );

      await openMenu(tester, running);
      await tester.tap(_key('desktop-dock-menu-quit'));
      await tester.pump();
      expect(_key('desktop-dock-running-app:skillHub'), findsNothing);
      expect(harness.selections, [ClientSection.agents]);
    });

    testWidgets('Chat Channels opens through the models pane channel', (
      tester,
    ) async {
      await pumpShell(tester, activeDestination: ClientSection.models);
      expect(
        titleOf(tester),
        desktopAppLabel(stringsOf(tester), DesktopAppId.modelsGateway),
      );

      await openQuickSwitcher(tester);
      harness.features.quickSwitcherOnOpenApp!('app:modelsChatChannels');
      await tester.pump();

      final pane = harness.scopedState!.readIfDeclaredFor(
        ClientSection.models,
        LayoutStateChannels.communicationSection,
      );
      expect(pane, isA<LayoutTabState>());
      expect((pane! as LayoutTabState).index, 1);
      expect(
        titleOf(tester),
        desktopAppLabel(stringsOf(tester), DesktopAppId.modelsChatChannels),
      );
      expect(
        _key('desktop-dock-running-app:modelsChatChannels'),
        findsOneWidget,
      );
    });
  });

  group('quick switcher', () {
    testWidgets('lists every app and every installed plugin window', (
      tester,
    ) async {
      harness.features.pluginState.value = const [_sketch];
      await pumpShell(tester);

      await openQuickSwitcher(tester);

      expect(harness.features.quickSwitcherOpens, 1);
      expect(harness.features.quickSwitcherApps.map((app) => app.id), [
        for (final app in DesktopAppId.values) 'app:${app.name}',
        'plugin:sketch',
      ]);
    });

    testWidgets('Cmd+K and Ctrl+K open it', (tester) async {
      await pumpShell(tester);
      Focus.of(tester.element(_key('desktop-work-area'))).requestFocus();
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pump();
      expect(harness.features.quickSwitcherOpens, 1);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(harness.features.quickSwitcherOpens, 2);
    });

    testWidgets('choosing an app opens it', (tester) async {
      await pumpShell(tester);
      await openQuickSwitcher(tester);

      harness.features.quickSwitcherOnOpenApp!('app:agentHub');
      await tester.pump();
      expect(harness.selections, [ClientSection.agentHub]);
    });
  });

  group('plugin windows', () {
    Future<void> openPlugin(WidgetTester tester, String id) async {
      await openQuickSwitcher(tester);
      harness.features.quickSwitcherOnOpenApp!('plugin:$id');
      await tester.pump();
    }

    testWidgets('an open plugin window shows in the work area and the dock '
        'plugin group', (tester) async {
      harness.features.pluginState.value = const [_sketch, _notes];
      await pumpShell(tester);
      expect(_key('desktop-dock-plugin-sketch'), findsNothing);
      expect(_key('desktop-dock-divider-plugins'), findsNothing);

      await openPlugin(tester, 'sketch');

      expect(harness.features.openedPlugins, ['sketch']);
      expect(harness.selections, isEmpty);
      expect(_key('fixture-plugin-window-sketch'), findsOneWidget);
      expect(_key('fixture-collaboration-app'), findsNothing);
      expect(
        titleOf(tester),
        'Sketch Board · '
        '${DesktopDesktopCopy.pluginPublisher(stringsOf(tester), official: true)}',
      );
      expect(_key('fixture-plugin-close-sketch'), findsOneWidget);

      final plugin = tester.getRect(_key('desktop-dock-plugin-sketch'));
      final pluginsDivider = tester.getRect(
        _key('desktop-dock-divider-plugins'),
      );
      final systemDivider = tester.getRect(_key('desktop-dock-divider-system'));
      expect(
        tester.getRect(_entry(DesktopAppId.devices)).right,
        lessThanOrEqualTo(pluginsDivider.left),
      );
      expect(pluginsDivider.right, lessThanOrEqualTo(plugin.left));
      expect(plugin.right, lessThanOrEqualTo(systemDivider.left));
      expect(dotColor(tester, 'plugin:sketch'), paletteOf(tester).primary);
      expect(_key('desktop-dock-plugin-notes'), findsNothing);
    });

    testWidgets('keep in dock pins a plugin window across closing it', (
      tester,
    ) async {
      harness.features.pluginState.value = const [_sketch];
      await pumpShell(tester);
      await openPlugin(tester, 'sketch');

      await openMenu(tester, _key('desktop-dock-plugin-sketch'));
      expect(_key('desktop-dock-menu-close'), findsOneWidget);
      expect(_key('desktop-dock-menu-remove'), findsNothing);
      await tester.tap(_key('desktop-dock-menu-keep'));
      await tester.pump();
      expect(dockModel.pinnedPlugins, ['sketch']);

      await tester.tap(_key('fixture-plugin-close-sketch'));
      await tester.pump();
      expect(harness.features.closedPlugins, ['sketch']);
      expect(_key('fixture-collaboration-app'), findsOneWidget);
      expect(
        find.byKey(
          const ValueKey<String>('desktop-work-slot-plugin-sketch'),
          skipOffstage: false,
        ),
        findsNothing,
      );
      // Pinned: still in the dock, without a running dot.
      expect(_key('desktop-dock-plugin-sketch'), findsOneWidget);
      expect(dotColor(tester, 'plugin:sketch'), Colors.transparent);

      await openMenu(tester, _key('desktop-dock-plugin-sketch'));
      expect(_key('desktop-dock-menu-close'), findsNothing);
      await tester.tap(_key('desktop-dock-menu-remove'));
      await tester.pump();
      expect(dockModel.pinnedPlugins, isEmpty);
      expect(_key('desktop-dock-plugin-sketch'), findsNothing);
    });

    testWidgets('a pinned plugin icon reopens its window', (tester) async {
      harness.features.pluginState.value = const [_sketch];
      dockModel.debugSeed(const [], pinnedPlugins: const ['sketch']);
      await pumpShell(tester);
      expect(_key('desktop-dock-plugin-sketch'), findsOneWidget);

      await tester.tap(_key('desktop-dock-plugin-sketch'));
      await tester.pump();
      expect(harness.features.openedPlugins, ['sketch']);
      expect(_key('fixture-plugin-window-sketch'), findsOneWidget);
    });

    testWidgets('permission settings open Plugin Center', (tester) async {
      harness.features.pluginState.value = const [_notes];
      await pumpShell(tester);
      await openPlugin(tester, 'notes');
      expect(
        titleOf(tester),
        'Notes · '
        '${DesktopDesktopCopy.pluginPublisher(stringsOf(tester), official: false)}',
      );

      await tester.tap(_key('fixture-plugin-permissions-notes'));
      await tester.pump();
      expect(harness.selections, [ClientSection.pluginManagement]);
    });

    testWidgets('uninstalling the active plugin falls back to the default '
        'app', (tester) async {
      harness.features.pluginState.value = const [_sketch];
      await pumpShell(tester);
      await openPlugin(tester, 'sketch');
      expect(_key('fixture-plugin-window-sketch'), findsOneWidget);

      harness.features.pluginState.value = const [];
      await tester.pump();

      expect(_key('fixture-plugin-window-sketch'), findsNothing);
      expect(_key('fixture-collaboration-app'), findsOneWidget);
      expect(_key('desktop-dock-plugin-sketch'), findsNothing);
    });
  });

  group('chat sidebar', () {
    testWidgets('installs the avatar-column directive', (tester) async {
      await pumpShell(tester);

      final directive = directiveOf(tester);
      expect(directive.sidebarMode, LayoutAgentsSidebarMode.avatarColumn);
      expect(directive.selectLocalGroupWhenIdle, isTrue);
      expect(directive.onToggleSwitcher, isNotNull);
      expect(directive.onCollapseSidebar, isNotNull);
    });

    testWidgets('dragging the handle resizes within 340-560 and persists the '
        'width', (tester) async {
      await pumpShell(tester);
      final handle = _key('desktop-sidebar-resize-handle');

      // The handle is the arena's only member, so it accepts on pointer
      // down and every moved pixel counts; the frame between move and up
      // mirrors a real drag, which lays out at full speed while dragging.
      Future<void> dragBy(double dx) async {
        final gesture = await tester.startGesture(tester.getCenter(handle));
        await gesture.moveBy(Offset(dx, 0));
        await tester.pump();
        await gesture.up();
        await tester.pump();
      }

      double width() => tester.getRect(_key('desktop-chat-sidebar')).width;

      await dragBy(-80);
      expect(width(), 480);
      final stored = harness.scopedState!.readIfDeclaredFor(
        ClientSection.agents,
        LayoutStateChannels.agentsSidebar,
      );
      expect(stored, isA<LayoutPaneExtentState>());
      expect((stored! as LayoutPaneExtentState).extent, 480);

      await dragBy(-1000);
      expect(width(), DesktopDesktopMetrics.sidebarMaxExtent);
      await dragBy(1000);
      expect(width(), DesktopDesktopMetrics.sidebarMinExtent);
    });

    testWidgets('collapses to the rail and expands back', (tester) async {
      await pumpShell(tester);

      directiveOf(tester).onCollapseSidebar!();
      await settle(tester);
      expect(
        tester.getRect(_key('desktop-chat-sidebar-viewport')).width,
        DesktopDesktopMetrics.sidebarRailExtent,
      );
      expect(
        directiveOf(tester).sidebarMode,
        LayoutAgentsSidebarMode.avatarRail,
      );
      expect(_key('desktop-sidebar-resize-handle'), findsNothing);
      expect(_key('desktop-fake-content-agents'), findsOneWidget);

      directiveOf(tester).onExpandSidebar!();
      await settle(tester);
      expect(
        tester.getRect(_key('desktop-chat-sidebar-viewport')).width,
        DesktopDesktopMetrics.sidebarDefaultExtent,
      );
      expect(
        directiveOf(tester).sidebarMode,
        LayoutAgentsSidebarMode.avatarColumn,
      );
    });

    testWidgets('the header switcher toggles and collapsing closes it', (
      tester,
    ) async {
      await pumpShell(tester);

      directiveOf(tester).onToggleSwitcher!();
      await tester.pump();
      expect(directiveOf(tester).switcherOpen, isTrue);

      directiveOf(tester).onCollapseSidebar!();
      await settle(tester);
      expect(directiveOf(tester).switcherOpen, isFalse);
    });
  });
  testWidgets('dark panes are clear glass — flat veil, no smoke region', (
    tester,
  ) async {
    LicoGalaxyProgram.debugLoaded = true;
    addTearDown(() => LicoGalaxyProgram.debugLoaded = false);
    await pumpShell(tester);
    for (final paneKey in const ['desktop-work-area', 'desktop-chat-sidebar']) {
      final container = tester
          .widgetList<Container>(
            find.descendant(
              of: _key(paneKey),
              matching: find.byType(Container),
            ),
          )
          .first;
      final decoration = container.decoration! as ShapeDecoration;
      expect(
        decoration.shadows ?? const <BoxShadow>[],
        isEmpty,
        reason: '$paneKey must not paint a shadow halo — clear glass',
      );
      // Clear glass: a flat veil, never a smoke/sheen gradient.
      expect(decoration.gradient, isNull);
      expect(decoration.color, LicoPaneGlass.paneGlassVeil);
      // The pane registers no smoke region, so the ambient shader does not
      // dim or fog the galaxy beneath it.
      final region = tester.widgetList<LicoGlassRegion>(
        find.descendant(
          of: _key(paneKey),
          matching: find.byType(LicoGlassRegion),
        ),
      );
      expect(region, hasLength(1));
      expect(region.first.softens, isFalse);
    }
  });
}
