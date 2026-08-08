import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_agents_strategy.dart';
import 'package:licoup/src/frontend/layout/layout_chrome_port.dart';
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
      // Right cluster order: tabs | search | bell, with notifications pinned
      // at the band's far-right edge.
      final tabsRect = tester.getRect(
        find.byKey(const Key('fixture-conversation-tabs')),
      );
      // Tabs clear the macOS traffic-light cluster (Dashboard reservation).
      expect(tabsRect.left, 96);
      final bellRect = tester.getRect(
        find.byKey(const Key('fixture-notification-bell')),
      );
      expect(tabsRect.left, lessThan(searchRect.left));
      expect(searchRect.right, lessThan(bellRect.left));
      expect(bellRect.right, bandRect.right - 10);
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
      // avatar/settings buttons.
      final firstButtonCenter = tester.getCenter(
        find.byKey(const Key('messaging-rail-nav-agents')),
      );
      final lastButtonCenter = tester.getCenter(
        find.byKey(const Key('messaging-rail-pairing-button')),
      );
      final avatarRect = tester.getRect(
        find.byKey(const Key('messaging-rail-avatar-button')),
      );
      final expectedCenter = (bandRect.bottom + avatarRect.top) / 2;
      expect(
        (((firstButtonCenter.dy + lastButtonCenter.dy) / 2) - expectedCenter)
            .abs(),
        lessThan(6),
      );
      // The avatar and settings are rounded-rect buttons anchored at the
      // rail's bottom-left.
      final settingsRect = tester.getRect(
        find.byKey(const Key('messaging-rail-settings-button')),
      );
      expect(avatarRect.top, greaterThan(lastButtonCenter.dy));
      expect(settingsRect.top, greaterThan(avatarRect.top));
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

  testWidgets(
    'avatar toggles the profile page and capsule selection closes it',
    (tester) async {
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

      expect(find.byKey(const Key('messaging-profile-page')), findsNothing);

      await tester.tap(find.byKey(const Key('messaging-rail-avatar-button')));
      await tester.pump();
      expect(find.byKey(const Key('messaging-profile-page')), findsOneWidget);
      expect(find.text('Local User'), findsOneWidget);
      expect(
        find.byKey(const Key('messaging-fake-content-agents')),
        findsNothing,
      );

      // Re-tapping the avatar closes it.
      await tester.tap(find.byKey(const Key('messaging-rail-avatar-button')));
      await tester.pump();
      expect(find.byKey(const Key('messaging-profile-page')), findsNothing);

      // Selecting any capsule destination closes it too.
      await tester.tap(find.byKey(const Key('messaging-rail-avatar-button')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('messaging-rail-nav-skillHub')));
      await tester.pump();
      expect(find.byKey(const Key('messaging-profile-page')), findsNothing);
      expect(harness.selections, [ClientSection.skillHub]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('avatar and settings are never active at the same time', (
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

    Color tileColor(Key key) {
      final container = tester.widget<AnimatedContainer>(
        find
            .descendant(
              of: find.byKey(key),
              matching: find.byType(AnimatedContainer),
            )
            .first,
      );
      return (container.decoration! as BoxDecoration).color!;
    }

    final colors = tester.element(
      find.byKey(const Key('messaging-desktop-shell')),
    );
    final primary = colors.licoColors.primary;
    // Settings destination alone activates the settings tile.
    expect(tileColor(const Key('messaging-rail-settings-button')), primary);

    // Opening the profile deactivates the settings tile while the avatar
    // tile takes the active treatment.
    await tester.tap(find.byKey(const Key('messaging-rail-avatar-button')));
    await tester.pump();
    expect(find.byKey(const Key('messaging-profile-page')), findsOneWidget);
    expect(
      tileColor(const Key('messaging-rail-settings-button')),
      isNot(primary),
    );
    expect(tileColor(const Key('messaging-rail-avatar-button')), primary);
    expect(tester.takeException(), isNull);
  });

  testWidgets('avatar deactivates the previously selected destination', (
    tester,
  ) async {
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

    Color tileColor(Key key) {
      final container = tester.widget<AnimatedContainer>(
        find
            .descendant(
              of: find.byKey(key),
              matching: find.byType(AnimatedContainer),
            )
            .first,
      );
      return (container.decoration! as BoxDecoration).color!;
    }

    final shellContext = tester.element(
      find.byKey(const Key('messaging-desktop-shell')),
    );
    final primary = shellContext.licoColors.primary;
    const modelsButton = Key('messaging-rail-nav-models');
    const avatarButton = Key('messaging-rail-avatar-button');

    expect(tileColor(modelsButton), primary);
    await tester.tap(find.byKey(avatarButton));
    await tester.pump();

    expect(find.byKey(const Key('messaging-profile-page')), findsOneWidget);
    expect(tileColor(modelsButton), isNot(primary));
    expect(tileColor(avatarButton), primary);
    expect(tester.takeException(), isNull);
  });

  testWidgets('profile quick actions navigate to pairing and settings', (
    tester,
  ) async {
    configureMessagingTestView(tester, const Size(1280, 700));
    final harness = MessagingDesktopHarness();
    final chrome = _RecordingChromePort();
    await tester.pumpWidget(
      MessagingDesktopTestShell(
        environment: messagingDesktopEnvironment(width: 1280, height: 700),
        activeDestination: ClientSection.agents,
        content: MessagingDesktopFixtureContent(harness),
        harness: harness,
        chrome: chrome,
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('messaging-rail-avatar-button')));
    await tester.pump();

    // Pairing is a destination page inside the unified card, never the
    // dialog, so the chrome pairing port stays untouched.
    await tester.tap(find.byKey(const Key('messaging-profile-pairing-action')));
    await tester.pump();
    expect(chrome.pairingCalls, 0);
    expect(harness.selections, [ClientSection.mobileRelay]);
    expect(find.byKey(const Key('messaging-profile-page')), findsNothing);

    await tester.tap(find.byKey(const Key('messaging-rail-avatar-button')));
    await tester.pump();
    await tester.tap(
      find.byKey(const Key('messaging-profile-settings-action')),
    );
    await tester.pump();
    expect(harness.selections, [
      ClientSection.mobileRelay,
      ClientSection.settings,
    ]);
    expect(find.byKey(const Key('messaging-profile-page')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

final class _RecordingChromePort implements LayoutChromePort {
  int pairingCalls = 0;
  int searchCalls = 0;

  @override
  LayoutChromeSnapshot get value => const LayoutChromeSnapshot.empty();

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}

  @override
  Future<void> openPairing(BuildContext context) async {
    pairingCalls += 1;
  }

  @override
  Future<void> openGlobalSearch(BuildContext context) async {
    searchCalls += 1;
  }
}
