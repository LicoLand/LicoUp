import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_agents_strategy.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/mobile/presentation/dashboard_mobile_destination_presentations.dart';

import 'dashboard_mobile_test_harness.dart';

void main() {
  testWidgets('compact shell renders header, content, and navigation overlay', (
    tester,
  ) async {
    configureDashboardMobileTestView(tester, const Size(390, 780));
    final harness = DashboardMobileHarness();
    await tester.pumpWidget(
      DashboardMobileTestShell(
        environment: dashboardMobileEnvironment(width: 390, height: 780),
        activeDestination: ClientSection.agents,
        content: DashboardMobileFixtureContent(harness),
        harness: harness,
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const Key('dashboard-mobile-compact-shell')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('dashboard-fake-content-agents')),
      findsOneWidget,
    );
    expect(harness.buildCalls, [ClientSection.agents]);

    await tester.tap(find.byKey(const Key('dashboard-mobile-menu-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      find.byKey(const Key('dashboard-mobile-navigation-overlay')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const Key('dashboard-mobile-compact-navigation-settings')),
    );
    await tester.pump();
    expect(harness.selections, [ClientSection.settings]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('medium shell renders the navigation rail and content', (
    tester,
  ) async {
    configureDashboardMobileTestView(tester, const Size(760, 900));
    final harness = DashboardMobileHarness();
    await tester.pumpWidget(
      DashboardMobileTestShell(
        environment: dashboardMobileEnvironment(width: 760, height: 900),
        activeDestination: ClientSection.settings,
        content: DashboardMobileFixtureContent(harness),
        harness: harness,
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const Key('dashboard-mobile-medium-shell')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('dashboard-mobile-medium-rail')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('dashboard-fake-content-settings')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const Key('dashboard-mobile-medium-navigation-agents')),
    );
    await tester.pump();
    expect(harness.selections, [ClientSection.agents]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('agents destination installs the messaging strategy', (
    tester,
  ) async {
    configureDashboardMobileTestView(tester, const Size(390, 780));
    final harness = DashboardMobileHarness();
    await tester.pumpWidget(
      DashboardMobileTestShell(
        environment: dashboardMobileEnvironment(width: 390, height: 780),
        activeDestination: ClientSection.agents,
        content: DashboardMobileFixtureContent(harness),
        harness: harness,
      ),
    );
    await tester.pump();

    final contentContext = tester.element(
      find.byKey(const Key('dashboard-fake-content-agents')),
    );
    expect(
      LayoutAgentsStrategyScope.maybeOf(contentContext),
      const AgentsPresentationStrategy.messaging(),
    );
  });

  // -------------------------------------------------------------------
  // The mobile shell owns exactly three ordered bottom tabs:
  // Pairing -> Chats -> Settings.
  // -------------------------------------------------------------------

  /// The required tab order, spelled out literally so a reordering of
  /// `MessagingMobileNavItem` (or of the bar's iteration) fails here.
  const requiredTabKeys = <String>[
    'messaging-mobile-nav-pairing',
    'messaging-mobile-nav-conversations',
    'messaging-mobile-nav-settings',
  ];

  /// Each tab's destination, spelled out literally so retargeting a tab
  /// (for example back onto the desktop 功能 tab's `agentHub`) fails here.
  const requiredTabDestinations = <String, ClientSection>{
    'messaging-mobile-nav-pairing': ClientSection.mobileRelay,
    'messaging-mobile-nav-conversations': ClientSection.agents,
    'messaging-mobile-nav-settings': ClientSection.settings,
  };

  /// The visible labels, which is what makes the tabs Pairing/Chats/Settings
  /// rather than 功能/对话/设置.
  const requiredTabLabels = <String, String>{
    'messaging-mobile-nav-pairing': 'Mobile Pairing',
    'messaging-mobile-nav-conversations': 'Chats',
    'messaging-mobile-nav-settings': 'Settings',
  };

  final mobileBottomNav = find.byKey(const Key('messaging-mobile-bottom-nav'));

  Finder mobileTab(String key) => find.byKey(Key(key));

  /// The mobile tabs actually present under the bar, in widget-tree order.
  List<String> renderedMobileTabKeys(WidgetTester tester) => tester
      .widgetList(
        find.descendant(
          of: mobileBottomNav,
          matching: find.byWidgetPredicate(
            (widget) =>
                widget.key is ValueKey<String> &&
                (widget.key! as ValueKey<String>).value.startsWith(
                  'messaging-mobile-nav-',
                ),
          ),
        ),
      )
      .map((widget) => (widget.key! as ValueKey<String>).value)
      .toList();

  /// Every viewport the mobile surface registers: both are the mobile shell,
  /// so both must carry the required bottom tabs.
  const mobileShellViewports = <String, ({double width, double height})>{
    'dashboard-mobile-compact-shell': (width: 390, height: 780),
    'dashboard-mobile-medium-shell': (width: 760, height: 900),
  };

  for (final viewport in mobileShellViewports.entries) {
    testWidgets(
      '${viewport.key} mounts the bottom bar as shell chrome with exactly '
      'three ordered tabs Pairing/Chats/Settings',
      (tester) async {
        final size = Size(viewport.value.width, viewport.value.height);
        configureDashboardMobileTestView(tester, size);
        final harness = DashboardMobileHarness();
        await tester.pumpWidget(
          DashboardMobileTestShell(
            environment: dashboardMobileEnvironment(
              width: viewport.value.width,
              height: viewport.value.height,
            ),
            activeDestination: ClientSection.agents,
            content: DashboardMobileFixtureContent(harness),
            harness: harness,
          ),
        );
        await tester.pump();

        final shell = find.byKey(Key(viewport.key));
        expect(shell, findsOneWidget);

        // Mounted: the bar is a descendant of the shell, not merely present
        // somewhere else in the widget tree.
        expect(mobileBottomNav, findsOneWidget);
        expect(
          find.descendant(of: shell, matching: mobileBottomNav),
          findsOneWidget,
        );

        // Owned by the shell: the destination content is a bare fixture, so
        // the bar cannot have come from it.
        expect(
          find.descendant(
            of: find.byKey(const Key('dashboard-fake-content-agents')),
            matching: mobileBottomNav,
          ),
          findsNothing,
        );

        // The desktop 功能/对话/设置 bar must not also be on the mobile shell.
        expect(
          find.byKey(const Key('messaging-sidebar-bottom-nav')),
          findsNothing,
        );

        // Exactly three tabs, in the required order.
        expect(renderedMobileTabKeys(tester), requiredTabKeys);
        for (final key in requiredTabKeys) {
          expect(mobileTab(key), findsOneWidget);
        }
        for (final label in requiredTabLabels.entries) {
          expect(
            find.descendant(
              of: mobileTab(label.key),
              matching: find.text(label.value),
            ),
            findsOneWidget,
          );
        }

        // Order is also geometric: left to right, on one row, below the
        // content — independent of the widget-tree order asserted above.
        final lefts = [
          for (final key in requiredTabKeys)
            tester.getTopLeft(mobileTab(key)).dx,
        ];
        expect(lefts[0], lessThan(lefts[1]));
        expect(lefts[1], lessThan(lefts[2]));
        final tops = [
          for (final key in requiredTabKeys)
            tester.getTopLeft(mobileTab(key)).dy,
        ];
        expect(tops.toSet(), hasLength(1));
        expect(
          tester.getTopLeft(mobileBottomNav).dy,
          greaterThanOrEqualTo(
            tester
                    .getBottomLeft(
                      find.byKey(const Key('dashboard-fake-content-agents')),
                    )
                    .dy -
                1,
          ),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final tab in requiredTabDestinations.entries) {
    // Start somewhere other than the tab's own destination, so the assertion
    // proves the tap reported the tab's target rather than echoing `current`.
    final startAt = tab.value == ClientSection.agents
        ? ClientSection.settings
        : ClientSection.agents;
    testWidgets('tapping ${tab.key} reaches ${tab.value.name}', (tester) async {
      configureDashboardMobileTestView(tester, const Size(390, 780));
      final harness = DashboardMobileHarness();
      await tester.pumpWidget(
        DashboardMobileTestShell(
          environment: dashboardMobileEnvironment(width: 390, height: 780),
          activeDestination: startAt,
          content: DashboardMobileFixtureContent(harness),
          harness: harness,
        ),
      );
      await tester.pump();

      expect(tab.value, isNot(startAt));
      await tester.tap(mobileTab(tab.key));
      await tester.pump();

      expect(harness.selections, <ClientSection>[tab.value]);
      expect(tester.takeException(), isNull);
    });
  }

  test('the mobile shell is the single owner of the mobile bottom tabs', () {
    // The Agents conversation list would otherwise re-add the desktop
    // 功能/对话/设置 row on the mobile surface, whose 功能 tab targets
    // `agentHub` — not a mobile destination at all.
    expect(dashboardMobileAgentsPresentation.showSidebarBottomNav, isFalse);
  });
}
