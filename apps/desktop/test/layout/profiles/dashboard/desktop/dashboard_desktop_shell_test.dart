import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/presentation/built_in_layout_spec.dart';
import 'package:licoup/src/frontend/shared/ui/lico_ambient_layer.dart';
import 'package:licoup/src/frontend/shared/ui/lico_pane_card.dart';
import 'package:licoup/src/frontend/shared/ui/lico_window_ground.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_agents_strategy.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/shell/dashboard_sidebar_navigation.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/tokens/dashboard_desktop_tokens.dart';

import 'dashboard_desktop_test_harness.dart';

void main() {
  test('single-pane destinations share one main-pane page inset', () {
    expect(
      MessagingDesktopMetrics.mainPanePadding,
      const EdgeInsets.fromLTRB(24, 20, 24, 40),
    );
  });

  test('features tab defaults to agent hub and keeps hosted destinations', () {
    expect(
      messagingSidebarNavTarget(
        item: MessagingSidebarNavItem.features,
        current: ClientSection.agents,
      ),
      ClientSection.agentHub,
    );
    expect(
      messagingSidebarNavTarget(
        item: MessagingSidebarNavItem.features,
        current: ClientSection.settings,
      ),
      ClientSection.agentHub,
    );
    for (final hosted in <ClientSection>[
      ClientSection.agentHub,
      ClientSection.models,
      ClientSection.devices,
      ClientSection.monitoring,
      ClientSection.pluginManagement,
      ClientSection.skillHub,
    ]) {
      expect(
        messagingSidebarNavTarget(
          item: MessagingSidebarNavItem.features,
          current: hosted,
        ),
        hosted,
      );
      expect(
        messagingSidebarNavItemSelected(
          item: MessagingSidebarNavItem.features,
          current: hosted,
        ),
        isTrue,
      );
    }
    expect(
      messagingSidebarNavItemSelected(
        item: MessagingSidebarNavItem.features,
        current: ClientSection.agents,
      ),
      isFalse,
    );
    expect(
      messagingSidebarNavItemSelected(
        item: MessagingSidebarNavItem.features,
        current: ClientSection.settings,
      ),
      isFalse,
    );
  });

  for (final width in <double>[900, 1280]) {
    testWidgets('shell renders the navigation card without top chrome at '
        '$width', (tester) async {
      configureDashboardTestView(tester, Size(width, 700));
      final harness = DashboardDesktopHarness();
      await tester.pumpWidget(
        DashboardDesktopTestShell(
          environment: dashboardDesktopEnvironment(width: width, height: 700),
          activeDestination: ClientSection.agentHub,
          content: DashboardDesktopFixtureContent(harness),
          harness: harness,
        ),
      );
      await tester.pump();

      expect(find.byKey(const Key('messaging-destination-rail')), findsNothing);
      expect(find.byKey(const Key('messaging-chrome-band')), findsNothing);
      expect(find.byKey(const Key('messaging-topstrip-search')), findsNothing);
      expect(
        find.byKey(const Key('messaging-chrome-usage-button')),
        findsNothing,
      );
      expect(find.byKey(const Key('fixture-notification-bell')), findsNothing);
      expect(find.byKey(const Key('fixture-conversation-tabs')), findsNothing);
      expect(
        find.byKey(const Key('dashboard-fake-content-agentHub')),
        findsOneWidget,
      );
      // Card style: no content-region veil or clip shell — the shell's
      // own window ground covers the window and the content floats as one
      // solid card inset 10 px from the window and the sidebar card.
      expect(find.byKey(const Key('dashboard-content-region')), findsNothing);
      expect(
        find.byKey(const Key('dashboard-desktop-main-card')),
        findsNothing,
      );
      expect(harness.buildCalls, [ClientSection.agentHub]);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('traffic-light row sits at the sidebar card top-left above the '
      'search capsule', (tester) async {
    configureDashboardTestView(tester, const Size(1280, 700));
    final harness = DashboardDesktopHarness();
    await tester.pumpWidget(
      DashboardDesktopTestShell(
        environment: dashboardDesktopEnvironment(width: 1280, height: 700),
        activeDestination: ClientSection.agentHub,
        content: DashboardDesktopFixtureContent(harness),
        harness: harness,
      ),
    );
    await tester.pump();

    final row = find.byKey(const Key('messaging-sidebar-traffic-light-row'));
    final anchor = find.byKey(const Key('messaging-traffic-light-anchor'));
    final search = find.byKey(const Key('messaging-sidebar-search'));
    expect(row, findsOneWidget);
    expect(anchor, findsOneWidget);
    expect(search, findsOneWidget);
    // No heading text above the search capsule anymore.
    expect(
      find.byKey(const Key('messaging-desktop-nav-sidebar-heading')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('messaging-contact-list-heading')),
      findsNothing,
    );

    final sidebarCard = tester.getRect(
      find.byKey(const Key('messaging-sidebar-column-card')),
    );
    final rowRect = tester.getRect(row);
    final anchorRect = tester.getRect(anchor);
    expect(rowRect.top, greaterThanOrEqualTo(sidebarCard.top));
    expect(
      rowRect.top - sidebarCard.top,
      lessThan(MessagingDesktopMetrics.trafficLightRowExtent),
    );
    expect(anchorRect.left, sidebarCard.left);
    expect(anchorRect.height, MessagingDesktopMetrics.trafficLightRowExtent);
    expect(anchorRect.width, MessagingDesktopMetrics.trafficLightAnchorExtent);
    expect(rowRect.bottom, lessThanOrEqualTo(tester.getRect(search).top));
    expect(tester.takeException(), isNull);
  });

  testWidgets('agents destination installs the messaging strategy', (
    tester,
  ) async {
    configureDashboardTestView(tester, const Size(1280, 700));
    final harness = DashboardDesktopHarness();
    await tester.pumpWidget(
      DashboardDesktopTestShell(
        environment: dashboardDesktopEnvironment(width: 1280, height: 700),
        activeDestination: ClientSection.agents,
        content: DashboardDesktopFixtureContent(harness),
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

  testWidgets('a late first visit to 对话 keeps the shared sidebar column '
      'alive', (tester) async {
    configureDashboardTestView(tester, const Size(1280, 700));
    final harness = DashboardDesktopHarness();
    final content = DashboardDesktopFixtureContent(harness);
    Future<void> pumpShell(ClientSection active) => tester.pumpWidget(
      DashboardDesktopTestShell(
        environment: dashboardDesktopEnvironment(width: 1280, height: 700),
        activeDestination: active,
        content: content,
        harness: harness,
      ),
    );
    Element sidebarColumnElement() => tester.element(
      find.byKey(const Key('messaging-sidebar-column'), skipOffstage: false),
    );

    // A restored session can land on a hosted destination without ever
    // having mounted the agents pane.
    await pumpShell(ClientSection.settings);
    await tester.pump();
    expect(
      find.byKey(const Key('dashboard-fake-content-settings')),
      findsOneWidget,
    );
    final columnOnLand = sidebarColumnElement();

    // Opening 对话 for the first time inserts the agents slot ahead of the
    // shared column in the slot stack; keyed slots must keep the column (and
    // every hosted pane inside it) mounted instead of remounting it.
    await pumpShell(ClientSection.agents);
    await tester.pump();
    expect(
      find.byKey(
        const Key('dashboard-fake-content-agents'),
        skipOffstage: false,
      ),
      findsOneWidget,
    );
    expect(identical(columnOnLand, sidebarColumnElement()), isTrue);
    // The settings pane stays mounted offstage behind the agents slot.
    expect(
      find.byKey(
        const Key('dashboard-fake-content-settings'),
        skipOffstage: false,
      ),
      findsOneWidget,
    );

    // Switching back keeps both slots alive.
    await pumpShell(ClientSection.settings);
    await tester.pump();
    expect(identical(columnOnLand, sidebarColumnElement()), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('monitoring keeps the shared sidebar column and search chrome', (
    tester,
  ) async {
    configureDashboardTestView(tester, const Size(1280, 700));
    final harness = DashboardDesktopHarness();
    await tester.pumpWidget(
      DashboardDesktopTestShell(
        environment: dashboardDesktopEnvironment(width: 1280, height: 700),
        activeDestination: ClientSection.monitoring,
        content: DashboardDesktopFixtureContent(harness),
        harness: harness,
      ),
    );
    await tester.pump();

    final contentContext = tester.element(
      find.byKey(const Key('dashboard-fake-content-monitoring')),
    );
    expect(
      LayoutAgentsStrategyScope.maybeOf(contentContext),
      const AgentsPresentationStrategy.console(),
    );
    // 统计面板 reuses the unified sidebar: feature list, search capsule,
    // bottom nav, and the resize handle all stay put; its content fills the
    // detail pane on the right.
    expect(find.byKey(const Key('messaging-sidebar-column')), findsOneWidget);
    expect(
      find.byKey(const Key('messaging-sidebar-foundation')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('messaging-sidebar-search')), findsOneWidget);
    expect(
      find.byKey(const Key('messaging-sidebar-list-statsPanel')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('messaging-sidebar-bottom-nav')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('messaging-sidebar-resize-handle')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('dashboard-shell-traffic-light-row')),
      findsNothing,
    );
    // The traffic-light anchor lives in the sidebar foundation row.
    expect(
      find.byKey(const Key('messaging-traffic-light-anchor')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('shell renders under a light preset', (tester) async {
    configureDashboardTestView(tester, const Size(1280, 700));
    final harness = DashboardDesktopHarness();
    await tester.pumpWidget(
      DashboardDesktopTestShell(
        environment: dashboardDesktopEnvironment(width: 1280, height: 700),
        activeDestination: ClientSection.agents,
        content: DashboardDesktopFixtureContent(harness),
        harness: harness,
        brightness: Brightness.light,
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('messaging-destination-rail')), findsNothing);
    expect(
      find.byKey(const Key('dashboard-fake-content-agents')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings destination hosts the section list in the sidebar', (
    tester,
  ) async {
    configureDashboardTestView(tester, const Size(1280, 700));
    final harness = DashboardDesktopHarness();
    await tester.pumpWidget(
      DashboardDesktopTestShell(
        environment: dashboardDesktopEnvironment(width: 1280, height: 700),
        activeDestination: ClientSection.settings,
        content: DashboardDesktopFixtureContent(harness),
        harness: harness,
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const Key('messaging-sidebar-foundation')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('messaging-desktop-nav-sidebar')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('messaging-sidebar-settings-list')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('messaging-sidebar-settings-appearance')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('messaging-sidebar-bottom-nav')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('dashboard-fake-content-settings')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const Key('messaging-sidebar-nav-conversations')),
    );
    await tester.pump();
    expect(harness.selections, [ClientSection.agents]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('bottom nav is exactly 功能/对话/设置 in order', (tester) async {
    configureDashboardTestView(tester, const Size(1280, 700));
    final harness = DashboardDesktopHarness();
    await tester.pumpWidget(
      DashboardDesktopTestShell(
        environment: dashboardDesktopEnvironment(width: 1280, height: 700),
        activeDestination: ClientSection.settings,
        content: DashboardDesktopFixtureContent(harness),
        harness: harness,
        locale: const Locale('zh'),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const Key('messaging-sidebar-nav-features')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('messaging-sidebar-nav-conversations')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('messaging-sidebar-nav-settings')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('messaging-sidebar-nav-communication')),
      findsNothing,
    );
    expect(find.byKey(const Key('messaging-sidebar-nav-skills')), findsNothing);
    final bottomNav = find.byKey(const Key('messaging-sidebar-bottom-nav'));
    expect(
      find.descendant(of: bottomNav, matching: find.text('功能')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: bottomNav, matching: find.text('对话')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: bottomNav, matching: find.text('设置')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: bottomNav, matching: find.text('通信')),
      findsNothing,
    );
    expect(
      tester
          .getTopLeft(find.byKey(const Key('messaging-sidebar-nav-features')))
          .dx,
      lessThan(
        tester
            .getTopLeft(
              find.byKey(const Key('messaging-sidebar-nav-conversations')),
            )
            .dx,
      ),
    );
    expect(
      tester
          .getTopLeft(
            find.byKey(const Key('messaging-sidebar-nav-conversations')),
          )
          .dx,
      lessThan(
        tester
            .getTopLeft(find.byKey(const Key('messaging-sidebar-nav-settings')))
            .dx,
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('功能 list shows the four visible entries in order and selects '
      'destinations with their panes', (tester) async {
    configureDashboardTestView(tester, const Size(1280, 700));
    final harness = DashboardDesktopHarness();
    await tester.pumpWidget(
      DashboardDesktopTestShell(
        environment: dashboardDesktopEnvironment(width: 1280, height: 700),
        activeDestination: ClientSection.agentHub,
        content: DashboardDesktopFixtureContent(harness),
        harness: harness,
        locale: const Locale('zh'),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(
      find.byKey(const Key('messaging-sidebar-feature-list')),
      findsOneWidget,
    );
    const order = <String>['agentHub', 'modelGateway', 'devices', 'statsPanel'];
    double? previousDy;
    for (final id in order) {
      final row = find.byKey(Key('messaging-sidebar-list-$id'));
      expect(row, findsOneWidget, reason: 'missing 功能 row $id');
      final dy = tester.getTopLeft(row).dy;
      if (previousDy != null) {
        expect(dy, greaterThan(previousDy), reason: '功能 order broken at $id');
      }
      previousDy = dy;
    }
    for (final label in <String>['智能体中心', '模型网关', '设备', '统计面板']) {
      expect(find.text(label), findsOneWidget, reason: 'missing label $label');
    }

    await tester.tap(
      find.byKey(const Key('messaging-sidebar-list-modelGateway')),
    );
    await tester.pump();
    expect(harness.selections, [ClientSection.models]);

    await tester.pumpWidget(
      DashboardDesktopTestShell(
        environment: dashboardDesktopEnvironment(width: 1280, height: 700),
        activeDestination: ClientSection.models,
        content: DashboardDesktopFixtureContent(harness),
        harness: harness,
        locale: const Locale('zh'),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('messaging-sidebar-list-devices')));
    await tester.pump();
    expect(harness.selections, [ClientSection.models, ClientSection.devices]);

    await tester.tap(
      find.byKey(const Key('messaging-sidebar-list-statsPanel')),
    );
    await tester.pump();
    expect(harness.selections.last, ClientSection.monitoring);
    expect(tester.takeException(), isNull);
  });

  testWidgets('entering features from settings opens agent hub', (
    tester,
  ) async {
    configureDashboardTestView(tester, const Size(1280, 700));
    final harness = DashboardDesktopHarness();
    await tester.pumpWidget(
      DashboardDesktopTestShell(
        environment: dashboardDesktopEnvironment(width: 1280, height: 700),
        activeDestination: ClientSection.settings,
        content: DashboardDesktopFixtureContent(harness),
        harness: harness,
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('messaging-sidebar-nav-features')));
    await tester.pump();
    expect(harness.selections, [ClientSection.agentHub]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reselecting features keeps the hosted destination', (
    tester,
  ) async {
    configureDashboardTestView(tester, const Size(1280, 700));
    final skillHarness = DashboardDesktopHarness();
    await tester.pumpWidget(
      DashboardDesktopTestShell(
        environment: dashboardDesktopEnvironment(width: 1280, height: 700),
        activeDestination: ClientSection.skillHub,
        content: DashboardDesktopFixtureContent(skillHarness),
        harness: skillHarness,
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('messaging-sidebar-nav-features')));
    await tester.pump();
    expect(skillHarness.selections, [ClientSection.skillHub]);

    final pluginHarness = DashboardDesktopHarness();
    await tester.pumpWidget(
      DashboardDesktopTestShell(
        environment: dashboardDesktopEnvironment(width: 1280, height: 700),
        activeDestination: ClientSection.pluginManagement,
        content: DashboardDesktopFixtureContent(pluginHarness),
        harness: pluginHarness,
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('messaging-sidebar-nav-features')));
    await tester.pump();
    expect(pluginHarness.selections, [ClientSection.pluginManagement]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('hosted lists use the shared resizable sidebar column', (
    tester,
  ) async {
    configureDashboardTestView(tester, const Size(1280, 700));
    final harness = DashboardDesktopHarness();
    await tester.pumpWidget(
      DashboardDesktopTestShell(
        environment: dashboardDesktopEnvironment(width: 1280, height: 700),
        activeDestination: ClientSection.settings,
        content: DashboardDesktopFixtureContent(harness),
        harness: harness,
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('messaging-sidebar-split')), findsOneWidget);
    expect(find.byKey(const Key('messaging-sidebar-column')), findsOneWidget);
    expect(
      find.byKey(const Key('messaging-sidebar-resize-handle')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('messaging-sidebar-settings-list')),
      findsOneWidget,
    );
    // The shared column opens at the golden-ratio default, which this window
    // width resolves to the golden cap.
    expect(
      tester.getSize(find.byKey(const Key('messaging-sidebar-column'))).width,
      MessagingDesktopMetrics.conversationListGoldenCapExtent,
    );

    final handleRect = tester.getRect(
      find.byKey(const Key('messaging-sidebar-resize-handle')),
    );
    await tester.dragFrom(
      Offset(handleRect.left + 2, handleRect.center.dy),
      const Offset(48, 0),
    );
    await tester.pump();
    final resized = tester
        .getSize(find.byKey(const Key('messaging-sidebar-column')))
        .width;
    expect(
      resized,
      greaterThan(MessagingDesktopMetrics.conversationListExtent),
    );

    await tester.pumpWidget(
      DashboardDesktopTestShell(
        environment: dashboardDesktopEnvironment(width: 1280, height: 700),
        activeDestination: ClientSection.skillHub,
        content: DashboardDesktopFixtureContent(harness),
        harness: harness,
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const Key('messaging-sidebar-feature-list')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('messaging-sidebar-resize-handle')),
      findsOneWidget,
    );
    expect(
      tester.getSize(find.byKey(const Key('messaging-sidebar-column'))).width,
      resized,
    );

    await tester.pumpWidget(
      DashboardDesktopTestShell(
        environment: dashboardDesktopEnvironment(width: 1280, height: 700),
        activeDestination: ClientSection.devices,
        content: DashboardDesktopFixtureContent(harness),
        harness: harness,
      ),
    );
    await tester.pump();

    expect(
      tester.getSize(find.byKey(const Key('messaging-sidebar-column'))).width,
      resized,
    );
    expect(
      find.byKey(const Key('messaging-sidebar-resize-handle')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  group('destination window grounds', () {
    // Agents mounts its own grounds inside the conversation workspace and
    // Agent Hub inside its panel; every other destination must paint the
    // shared opaque ground or the host desktop shows through the window.

    // Messages frames its own content card inside the conversation
    // workspace (the plain agents presentation's `frameDetail`), so the
    // fixture destination carries no card of its own.

    for (final style in [
      BuiltInLayoutSpec.dashboardPlainStyleId,
      BuiltInLayoutSpec.dashboardCardStyleId,
    ]) {
      for (final destination in dashboardDesktopExpectedDestinations) {
        testWidgets(
          '${style.value} ${destination.name} sits on an opaque ground',
          (tester) async {
            final harness = DashboardDesktopHarness();
            await tester.pumpWidget(
              DashboardDesktopTestShell(
                environment: dashboardDesktopEnvironment(
                  width: 1280,
                  height: 800,
                ),
                activeDestination: destination,
                content: DashboardDesktopFixtureContent(harness),
                harness: harness,
                style: style,
              ),
            );
            await tester.pump();

            final marker = find.byKey(
              ValueKey<String>('dashboard-fake-content-${destination.name}'),
            );
            final grounds = tester.widgetList<LicoWindowGround>(
              find.ancestor(
                of: marker,
                matching: find.byType(LicoWindowGround),
              ),
            );
            if (style == BuiltInLayoutSpec.dashboardPlainStyleId) {
              // Plain is flat: no content card, no band. Every non-Messages
              // destination sits on the shell's flat detail ground — one
              // opaque fill that owns the ground scope so feature-owned
              // grounds keep their fill but mount no ambient layer; the
              // ambient never mounts under the plain style.
              expect(
                find.ancestor(of: marker, matching: find.byType(LicoPaneCard)),
                findsNothing,
                reason: '${destination.name} must not sit inside a card',
              );
              // The shell ground owns the one ambient layer for the
              // whole window in dark — every destination shares it.
              expect(
                find.byType(LicoAmbientLayer),
                findsOneWidget,
                reason:
                    'plain ${destination.name}: the shell ground owns the '
                    'ambient layer in dark',
              );
              expect(
                grounds.any((ground) => ground.color.a == 1.0),
                isTrue,
                reason:
                    '${destination.name} must paint a fully opaque '
                    'detail surface',
              );
            } else {
              // Card: the shell mounts the single ambient-owning ground
              // for the whole window; a destination's own nested ground
              // paints fill only. Messages sits on the shell ground;
              // every hosted destination sits inside the opaque content
              // card on it.
              expect(grounds.last.color.a, 1.0);
              expect(
                find.byType(LicoAmbientLayer),
                findsOneWidget,
                reason:
                    'card ${destination.name}: exactly one ambient layer '
                    'at shell level',
              );
              if (destination != ClientSection.agents) {
                expect(
                  find.ancestor(
                    of: marker,
                    matching: find.byKey(
                      const Key('dashboard-card-content-card'),
                    ),
                  ),
                  findsOneWidget,
                  reason:
                      'card ${destination.name} sits inside the opaque '
                      'content card',
                );
              }
            }
          },
        );
      }
    }
  });
}
