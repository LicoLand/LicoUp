import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_agents_strategy.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/shell/messaging_sidebar_navigation.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/tokens/messaging_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

import 'messaging_desktop_test_harness.dart';

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
        item: MessagingSidebarNavItem.skills,
        current: ClientSection.agents,
      ),
      ClientSection.agentHub,
    );
    expect(
      messagingSidebarNavTarget(
        item: MessagingSidebarNavItem.skills,
        current: ClientSection.models,
      ),
      ClientSection.agentHub,
    );
    expect(
      messagingSidebarNavTarget(
        item: MessagingSidebarNavItem.skills,
        current: ClientSection.agentHub,
      ),
      ClientSection.agentHub,
    );
    expect(
      messagingSidebarNavTarget(
        item: MessagingSidebarNavItem.skills,
        current: ClientSection.skillHub,
      ),
      ClientSection.skillHub,
    );
    expect(
      messagingSidebarNavTarget(
        item: MessagingSidebarNavItem.skills,
        current: ClientSection.pluginManagement,
      ),
      ClientSection.pluginManagement,
    );
  });

  for (final width in <double>[900, 1280]) {
    testWidgets('shell renders band and unified card at $width', (
      tester,
    ) async {
      configureMessagingTestView(tester, Size(width, 700));
      final harness = MessagingDesktopHarness();
      await tester.pumpWidget(
        MessagingDesktopTestShell(
          environment: messagingDesktopEnvironment(width: width, height: 700),
          activeDestination: ClientSection.agents,
          content: MessagingDesktopFixtureContent(harness),
          harness: harness,
        ),
      );
      await tester.pump();

      expect(find.byKey(const Key('messaging-destination-rail')), findsNothing);
      expect(find.byKey(const Key('messaging-chrome-band')), findsOneWidget);
      expect(find.byKey(const Key('messaging-topstrip-search')), findsNothing);
      expect(
        find.byKey(const Key('messaging-fake-content-agents')),
        findsOneWidget,
      );
      final card = tester.widget<Container>(
        find.byKey(const Key('messaging-desktop-main-card')),
      );
      final cardDecoration = card.decoration! as BoxDecoration;
      expect((cardDecoration.borderRadius! as BorderRadius).topLeft.x, 16);
      expect(card.clipBehavior, Clip.antiAlias);
      final cardRect = tester.getRect(
        find.byKey(const Key('messaging-desktop-main-card')),
      );
      expect(cardRect.top, 48);
      expect(cardRect.left, MessagingDesktopMetrics.mainCardMargin);
      expect(width - cardRect.right, MessagingDesktopMetrics.mainCardMargin);
      expect(700 - cardRect.bottom, MessagingDesktopMetrics.mainCardMargin);
      final bandRect = tester.getRect(
        find.byKey(const Key('messaging-chrome-band')),
      );
      expect(bandRect.left, 0);
      expect(bandRect.width, width);
      expect(bandRect.height, 48);
      final tabsRect = tester.getRect(
        find.byKey(const Key('fixture-conversation-tabs')),
      );
      expect(tabsRect.left, 96);
      final usageRect = tester.getRect(
        find.byKey(const Key('messaging-chrome-usage-button')),
      );
      final bellRect = tester.getRect(
        find.byKey(const Key('fixture-notification-bell')),
      );
      expect(tabsRect.right, lessThan(usageRect.left));
      expect(usageRect.right, lessThan(bellRect.left));
      expect(bellRect.right, bandRect.right - 10);
      final band = find.byKey(const Key('messaging-chrome-band'));
      expect(
        find.descendant(of: band, matching: find.byType(BackdropFilter)),
        findsNothing,
      );
      expect(
        find.byKey(const Key('messaging-rail-avatar-button')),
        findsNothing,
      );
      expect(harness.buildCalls, [ClientSection.agents]);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('agents destination installs the messaging strategy', (
    tester,
  ) async {
    configureMessagingTestView(tester, const Size(1280, 700));
    final harness = MessagingDesktopHarness();
    await tester.pumpWidget(
      MessagingDesktopTestShell(
        environment: messagingDesktopEnvironment(width: 1280, height: 700),
        activeDestination: ClientSection.agents,
        content: MessagingDesktopFixtureContent(harness),
        harness: harness,
      ),
    );
    await tester.pump();

    final contentContext = tester.element(
      find.byKey(const Key('messaging-fake-content-agents')),
    );
    expect(
      LayoutAgentsStrategyScope.maybeOf(contentContext),
      const AgentsPresentationStrategy.messaging(),
    );
  });

  testWidgets('console strategy stays intact outside the agents destination', (
    tester,
  ) async {
    configureMessagingTestView(tester, const Size(1280, 700));
    final harness = MessagingDesktopHarness();
    await tester.pumpWidget(
      MessagingDesktopTestShell(
        environment: messagingDesktopEnvironment(width: 1280, height: 700),
        activeDestination: ClientSection.monitoring,
        content: MessagingDesktopFixtureContent(harness),
        harness: harness,
      ),
    );
    await tester.pump();

    final contentContext = tester.element(
      find.byKey(const Key('messaging-fake-content-monitoring')),
    );
    expect(
      LayoutAgentsStrategyScope.maybeOf(contentContext),
      const AgentsPresentationStrategy.console(),
    );
    expect(find.byKey(const Key('messaging-topstrip-search')), findsOneWidget);
    expect(find.byKey(const Key('messaging-sidebar-column')), findsNothing);
    expect(find.byKey(const Key('messaging-sidebar-foundation')), findsNothing);
    expect(find.byKey(const Key('messaging-sidebar-bottom-nav')), findsNothing);
    expect(
      find.byKey(const Key('messaging-sidebar-resize-handle')),
      findsNothing,
    );
    expect(
      tester
          .widget<Icon>(
            find.descendant(
              of: find.byKey(const Key('messaging-topstrip-search')),
              matching: find.byType(Icon),
            ),
          )
          .icon,
      Icons.search_rounded,
    );
  });

  testWidgets('usage icon sits left of notifications and selects monitoring', (
    tester,
  ) async {
    configureMessagingTestView(tester, const Size(1280, 700));
    final harness = MessagingDesktopHarness();
    await tester.pumpWidget(
      MessagingDesktopTestShell(
        environment: messagingDesktopEnvironment(width: 1280, height: 700),
        activeDestination: ClientSection.agents,
        content: MessagingDesktopFixtureContent(harness),
        harness: harness,
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('messaging-chrome-usage-button')));
    await tester.pump();
    expect(harness.selections, [ClientSection.monitoring]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('usage icon uses house selection on the monitoring destination', (
    tester,
  ) async {
    configureMessagingTestView(tester, const Size(1280, 700));
    final harness = MessagingDesktopHarness();
    await tester.pumpWidget(
      MessagingDesktopTestShell(
        environment: messagingDesktopEnvironment(width: 1280, height: 700),
        activeDestination: ClientSection.monitoring,
        content: MessagingDesktopFixtureContent(harness),
        harness: harness,
      ),
    );
    await tester.pump();

    final colors = tester
        .element(find.byKey(const Key('messaging-desktop-shell')))
        .licoColors;
    final usage = find.byKey(const Key('messaging-chrome-usage-button'));
    final fill = tester.widget<AnimatedContainer>(
      find.descendant(of: usage, matching: find.byType(AnimatedContainer)),
    );
    expect((fill.decoration! as BoxDecoration).color, colors.primary);
    final icon = tester.widget<Icon>(
      find.descendant(of: usage, matching: find.byType(Icon)),
    );
    expect(icon.color, colors.textOnPrimary);
    await tester.tap(usage);
    await tester.pump();
    expect(harness.selections, [ClientSection.agents]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shell renders under a light preset', (tester) async {
    configureMessagingTestView(tester, const Size(1280, 700));
    final harness = MessagingDesktopHarness();
    await tester.pumpWidget(
      MessagingDesktopTestShell(
        environment: messagingDesktopEnvironment(width: 1280, height: 700),
        activeDestination: ClientSection.agents,
        content: MessagingDesktopFixtureContent(harness),
        harness: harness,
        brightness: Brightness.light,
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('messaging-destination-rail')), findsNothing);
    expect(
      find.byKey(const Key('messaging-fake-content-agents')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings destination hosts the section list in the sidebar', (
    tester,
  ) async {
    configureMessagingTestView(tester, const Size(1280, 700));
    final harness = MessagingDesktopHarness();
    await tester.pumpWidget(
      MessagingDesktopTestShell(
        environment: messagingDesktopEnvironment(width: 1280, height: 700),
        activeDestination: ClientSection.settings,
        content: MessagingDesktopFixtureContent(harness),
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
      find.byKey(const Key('messaging-fake-content-settings')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('messaging-topstrip-search')), findsNothing);

    await tester.tap(
      find.byKey(const Key('messaging-sidebar-nav-conversations')),
    );
    await tester.pump();
    expect(harness.selections, [ClientSection.agents]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('skills and plugins are separate hosted sidebar items', (
    tester,
  ) async {
    configureMessagingTestView(tester, const Size(1280, 700));
    final harness = MessagingDesktopHarness();
    await tester.pumpWidget(
      MessagingDesktopTestShell(
        environment: messagingDesktopEnvironment(width: 1280, height: 700),
        activeDestination: ClientSection.skillHub,
        content: MessagingDesktopFixtureContent(harness),
        harness: harness,
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const Key('messaging-sidebar-foundation')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('messaging-sidebar-skill-plugin-list')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('messaging-sidebar-list-skillHub')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('messaging-sidebar-list-pluginManagement')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('messaging-sidebar-list-agentHub')),
      findsOneWidget,
    );
    final hubIcon = tester.widget<Icon>(
      find.descendant(
        of: find.byKey(const Key('messaging-sidebar-list-agentHub')),
        matching: find.byType(Icon),
      ),
    );
    expect(hubIcon.icon, Icons.auto_awesome_outlined);
    expect(
      tester
          .getTopLeft(find.byKey(const Key('messaging-sidebar-list-agentHub')))
          .dy,
      lessThan(
        tester
            .getTopLeft(
              find.byKey(const Key('messaging-sidebar-list-skillHub')),
            )
            .dy,
      ),
    );
    expect(
      tester
          .getTopLeft(find.byKey(const Key('messaging-sidebar-list-skillHub')))
          .dy,
      lessThan(
        tester
            .getTopLeft(
              find.byKey(const Key('messaging-sidebar-list-pluginManagement')),
            )
            .dy,
      ),
    );
    expect(find.byKey(const Key('skill-plugin-hub-toggle')), findsNothing);
    expect(
      find.byKey(const Key('messaging-desktop-nav-sidebar-heading')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('messaging-sidebar-search')), findsOneWidget);
    expect(
      tester
          .getTopLeft(
            find.byKey(const Key('messaging-desktop-nav-sidebar-heading')),
          )
          .dy,
      lessThan(
        tester.getTopLeft(find.byKey(const Key('messaging-sidebar-search'))).dy,
      ),
    );
    expect(
      tester.getTopLeft(find.byKey(const Key('messaging-sidebar-search'))).dy,
      lessThan(
        tester
            .getTopLeft(
              find.byKey(const Key('messaging-sidebar-list-agentHub')),
            )
            .dy,
      ),
    );
    expect(
      find.byKey(const Key('messaging-sidebar-nav-skills')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('messaging-sidebar-nav-conversations')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('messaging-sidebar-nav-communication')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('messaging-sidebar-nav-settings')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const Key('messaging-sidebar-list-pluginManagement')),
    );
    await tester.pump();
    expect(harness.selections, [ClientSection.pluginManagement]);

    await tester.tap(find.byKey(const Key('messaging-sidebar-list-agentHub')));
    await tester.pump();
    expect(harness.selections, [
      ClientSection.pluginManagement,
      ClientSection.agentHub,
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('entering features opens agent hub', (tester) async {
    configureMessagingTestView(tester, const Size(1280, 700));
    final harness = MessagingDesktopHarness();
    await tester.pumpWidget(
      MessagingDesktopTestShell(
        environment: messagingDesktopEnvironment(width: 1280, height: 700),
        activeDestination: ClientSection.settings,
        content: MessagingDesktopFixtureContent(harness),
        harness: harness,
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('messaging-sidebar-nav-skills')));
    await tester.pump();
    expect(harness.selections, [ClientSection.agentHub]);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'reselecting features keeps skills and plugins without yanking to hub',
    (tester) async {
      configureMessagingTestView(tester, const Size(1280, 700));
      final skillHarness = MessagingDesktopHarness();
      await tester.pumpWidget(
        MessagingDesktopTestShell(
          environment: messagingDesktopEnvironment(width: 1280, height: 700),
          activeDestination: ClientSection.skillHub,
          content: MessagingDesktopFixtureContent(skillHarness),
          harness: skillHarness,
        ),
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('messaging-sidebar-nav-skills')));
      await tester.pump();
      expect(skillHarness.selections, [ClientSection.skillHub]);

      final pluginHarness = MessagingDesktopHarness();
      await tester.pumpWidget(
        MessagingDesktopTestShell(
          environment: messagingDesktopEnvironment(width: 1280, height: 700),
          activeDestination: ClientSection.pluginManagement,
          content: MessagingDesktopFixtureContent(pluginHarness),
          harness: pluginHarness,
        ),
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('messaging-sidebar-nav-skills')));
      await tester.pump();
      expect(pluginHarness.selections, [ClientSection.pluginManagement]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('communication hosts gateway, pairing, and chat-channel rows', (
    tester,
  ) async {
    configureMessagingTestView(tester, const Size(1280, 700));
    final harness = MessagingDesktopHarness();
    await tester.pumpWidget(
      MessagingDesktopTestShell(
        environment: messagingDesktopEnvironment(width: 1280, height: 700),
        activeDestination: ClientSection.mobileRelay,
        content: MessagingDesktopFixtureContent(harness),
        harness: harness,
        locale: const Locale('zh'),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const Key('messaging-sidebar-foundation')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('messaging-sidebar-communication-list')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('messaging-sidebar-list-modelGateway')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('messaging-sidebar-list-mobilePairing')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('messaging-sidebar-list-chatChannels')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('messaging-desktop-nav-sidebar-heading')),
      findsOneWidget,
    );
    expect(find.text('模型网关'), findsOneWidget);
    expect(find.text('移动配对'), findsWidgets);
    expect(find.text('聊天频道'), findsOneWidget);
    expect(find.text('密钥'), findsNothing);
    expect(find.text('配对'), findsNothing);
    expect(find.byKey(const Key('messaging-contact-list')), findsNothing);
    expect(find.byKey(const Key('messaging-sidebar-search')), findsNothing);
    expect(
      tester
          .getTopLeft(
            find.byKey(const Key('messaging-sidebar-list-modelGateway')),
          )
          .dy,
      lessThan(
        tester
            .getTopLeft(
              find.byKey(const Key('messaging-sidebar-list-mobilePairing')),
            )
            .dy,
      ),
    );
    expect(
      tester
          .getTopLeft(
            find.byKey(const Key('messaging-sidebar-list-mobilePairing')),
          )
          .dy,
      lessThan(
        tester
            .getTopLeft(
              find.byKey(const Key('messaging-sidebar-list-chatChannels')),
            )
            .dy,
      ),
    );

    await tester.tap(
      find.byKey(const Key('messaging-sidebar-list-modelGateway')),
    );
    await tester.pump();
    await tester.tap(
      find.byKey(const Key('messaging-sidebar-list-chatChannels')),
    );
    await tester.pump();
    expect(harness.selections, [ClientSection.models, ClientSection.models]);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'keys destination uses the shared foundation and communication list',
    (tester) async {
      configureMessagingTestView(tester, const Size(1280, 700));
      final harness = MessagingDesktopHarness();
      await tester.pumpWidget(
        MessagingDesktopTestShell(
          environment: messagingDesktopEnvironment(width: 1280, height: 700),
          activeDestination: ClientSection.models,
          content: MessagingDesktopFixtureContent(harness),
          harness: harness,
        ),
      );
      await tester.pump();

      expect(
        find.byKey(const Key('messaging-sidebar-foundation')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('messaging-sidebar-communication-list')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('messaging-fake-content-models')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('messaging-contact-list')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('hosted lists use the shared resizable sidebar column', (
    tester,
  ) async {
    configureMessagingTestView(tester, const Size(1280, 700));
    final harness = MessagingDesktopHarness();
    await tester.pumpWidget(
      MessagingDesktopTestShell(
        environment: messagingDesktopEnvironment(width: 1280, height: 700),
        activeDestination: ClientSection.settings,
        content: MessagingDesktopFixtureContent(harness),
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
    expect(
      tester.getSize(find.byKey(const Key('messaging-sidebar-column'))).width,
      MessagingDesktopMetrics.conversationListExtent,
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
      MessagingDesktopTestShell(
        environment: messagingDesktopEnvironment(width: 1280, height: 700),
        activeDestination: ClientSection.skillHub,
        content: MessagingDesktopFixtureContent(harness),
        harness: harness,
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const Key('messaging-sidebar-skill-plugin-list')),
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
      MessagingDesktopTestShell(
        environment: messagingDesktopEnvironment(width: 1280, height: 700),
        activeDestination: ClientSection.mobileRelay,
        content: MessagingDesktopFixtureContent(harness),
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
}
