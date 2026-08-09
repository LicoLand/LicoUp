import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_agents_strategy.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/tokens/messaging_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

import 'messaging_desktop_test_harness.dart';

void main() {
  for (final width in <double>[900, 1280]) {
    testWidgets('shell renders band, rail, and unified card at $width', (
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

      expect(
        find.byKey(const Key('messaging-destination-rail')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('messaging-chrome-band')), findsOneWidget);
      expect(
        find.byKey(const Key('messaging-topstrip-search')),
        findsOneWidget,
      );
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
      // The card sits below the full-width chrome band, flush against the
      // rail, floating off the window's right and bottom edges.
      final cardRect = tester.getRect(
        find.byKey(const Key('messaging-desktop-main-card')),
      );
      expect(cardRect.top, 48);
      expect(cardRect.left, 56);
      expect(width - cardRect.right, 8);
      expect(700 - cardRect.bottom, 8);
      // The chrome band spans the full window width with the search capsule
      // inside it.
      final bandRect = tester.getRect(
        find.byKey(const Key('messaging-chrome-band')),
      );
      expect(bandRect.left, 0);
      expect(bandRect.width, width);
      expect(bandRect.height, 48);
      final searchRect = tester.getRect(
        find.byKey(const Key('messaging-topstrip-search')),
      );
      expect(searchRect.top, greaterThanOrEqualTo(bandRect.top));
      expect(searchRect.bottom, lessThanOrEqualTo(bandRect.bottom));
      expect(searchRect.width, 200);
      // Right cluster order: tabs | bell | search, with the stadium search
      // field pinned at the band's far right edge.
      final tabsRect = tester.getRect(
        find.byKey(const Key('fixture-conversation-tabs')),
      );
      // Tabs clear the macOS traffic-light cluster (Dashboard reservation).
      expect(tabsRect.left, 96);
      final bellRect = tester.getRect(
        find.byKey(const Key('fixture-notification-bell')),
      );
      expect(tabsRect.left, lessThan(bellRect.left));
      expect(bellRect.left, lessThan(searchRect.left));
      expect(searchRect.right, bandRect.right - 10);
      // The band stays frosted glass: native blur only — no Flutter tint overlay.
      final band = find.byKey(const Key('messaging-chrome-band'));
      expect(
        find.descendant(of: band, matching: find.byType(BackdropFilter)),
        findsNothing,
      );
      final bandTint = tester.widget<ColoredBox>(
        find.descendant(of: band, matching: find.byType(ColoredBox)).first,
      );
      expect(
        (bandTint.color.a * 255.0).round(),
        MessagingDesktopMetrics.chromeTintDarkAlpha,
      );
      expect(bandTint.color, Colors.transparent);
      // A selected destination renders a brand-yellow rounded tile with a
      // black icon; unselected stays a plain muted icon.
      final shellContext = tester.element(
        find.byKey(const Key('messaging-desktop-shell')),
      );
      final selectedToggle = tester.widget<AnimatedContainer>(
        find
            .descendant(
              of: find.byKey(const Key('messaging-rail-nav-agents')),
              matching: find.byType(AnimatedContainer),
            )
            .first,
      );
      final selectedDecoration = selectedToggle.decoration! as BoxDecoration;
      expect(selectedDecoration.shape, BoxShape.rectangle);
      expect(selectedDecoration.color, shellContext.licoColors.primary);
      expect(selectedDecoration.borderRadius, BorderRadius.circular(12));
      final selectedIcon = tester.widget<Icon>(
        find
            .descendant(
              of: find.byKey(const Key('messaging-rail-nav-agents')),
              matching: find.byType(Icon),
            )
            .first,
      );
      // Ink on the lemon fill comes from the role, not a hardcoded black.
      expect(selectedIcon.color, shellContext.licoColors.textOnPrimary);
      // The rail's destination group (four destinations plus the pairing
      // page) is vertically centered in the zone above the bottom
      // settings button.
      final firstButtonCenter = tester.getCenter(
        find.byKey(const Key('messaging-rail-nav-agents')),
      );
      final lastButtonCenter = tester.getCenter(
        find.byKey(const Key('messaging-rail-pairing-button')),
      );
      final settingsRect = tester.getRect(
        find.byKey(const Key('messaging-rail-settings-button')),
      );
      final expectedCenter = (bandRect.bottom + settingsRect.top) / 2;
      expect(
        (((firstButtonCenter.dy + lastButtonCenter.dy) / 2) - expectedCenter)
            .abs(),
        lessThan(6),
      );
      // Settings is a rounded-rect button anchored at the rail's bottom.
      expect(settingsRect.top, greaterThan(lastButtonCenter.dy));
      expect(
        find.byKey(const Key('messaging-rail-avatar-button')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('messaging-destination-capsule')),
        findsNothing,
      );
      expect(find.byKey(const Key('messaging-account-capsule')), findsNothing);
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
  });

  testWidgets('rail selection routes to the destination callback', (
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

    await tester.tap(find.byKey(const Key('messaging-rail-nav-skillHub')));
    await tester.pump();
    expect(harness.selections, [ClientSection.skillHub]);

    await tester.tap(find.byKey(const Key('messaging-rail-nav-monitoring')));
    await tester.pump();
    expect(harness.selections, [
      ClientSection.skillHub,
      ClientSection.monitoring,
    ]);

    // The rail pairing button selects the pairing destination page rather
    // than opening the pairing dialog.
    await tester.tap(find.byKey(const Key('messaging-rail-pairing-button')));
    await tester.pump();
    expect(harness.selections, [
      ClientSection.skillHub,
      ClientSection.monitoring,
      ClientSection.mobileRelay,
    ]);
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

    expect(find.byKey(const Key('messaging-destination-rail')), findsOneWidget);
    expect(
      find.byKey(const Key('messaging-fake-content-agents')),
      findsOneWidget,
    );
    // Light preset relies on native VE only — no Flutter tint overlay.
    final bandTint = tester.widget<ColoredBox>(
      find
          .descendant(
            of: find.byKey(const Key('messaging-chrome-band')),
            matching: find.byType(ColoredBox),
          )
          .first,
    );
    expect(
      (bandTint.color.a * 255.0).round(),
      MessagingDesktopMetrics.lightSurfaceGlassAlpha,
    );
    expect(bandTint.color, Colors.transparent);
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings destination activates the settings rail tile', (
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

    final container = tester.widget<AnimatedContainer>(
      find
          .descendant(
            of: find.byKey(const Key('messaging-rail-settings-button')),
            matching: find.byType(AnimatedContainer),
          )
          .first,
    );
    final colors = tester.element(
      find.byKey(const Key('messaging-desktop-shell')),
    );
    expect(
      (container.decoration! as BoxDecoration).color,
      colors.licoColors.primary,
    );
    expect(find.byKey(const Key('messaging-rail-avatar-button')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
