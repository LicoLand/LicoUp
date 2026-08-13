import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_agents_strategy.dart';

import 'messaging_mobile_test_harness.dart';

void main() {
  testWidgets('compact shell renders header, content, and navigation overlay', (
    tester,
  ) async {
    configureMessagingMobileTestView(tester, const Size(390, 780));
    final harness = MessagingMobileHarness();
    await tester.pumpWidget(
      MessagingMobileTestShell(
        environment: messagingMobileEnvironment(width: 390, height: 780),
        activeDestination: ClientSection.agents,
        content: MessagingMobileFixtureContent(harness),
        harness: harness,
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const Key('messaging-mobile-compact-shell')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('messaging-fake-content-agents')),
      findsOneWidget,
    );
    expect(harness.buildCalls, [ClientSection.agents]);

    await tester.tap(find.byKey(const Key('messaging-mobile-menu-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      find.byKey(const Key('messaging-mobile-navigation-overlay')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const Key('messaging-mobile-compact-navigation-settings')),
    );
    await tester.pump();
    expect(harness.selections, [ClientSection.settings]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('medium shell renders the navigation rail and content', (
    tester,
  ) async {
    configureMessagingMobileTestView(tester, const Size(760, 900));
    final harness = MessagingMobileHarness();
    await tester.pumpWidget(
      MessagingMobileTestShell(
        environment: messagingMobileEnvironment(width: 760, height: 900),
        activeDestination: ClientSection.settings,
        content: MessagingMobileFixtureContent(harness),
        harness: harness,
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const Key('messaging-mobile-medium-shell')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('messaging-mobile-medium-rail')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('messaging-fake-content-settings')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const Key('messaging-mobile-medium-navigation-agents')),
    );
    await tester.pump();
    expect(harness.selections, [ClientSection.agents]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('agents destination installs the messaging strategy', (
    tester,
  ) async {
    configureMessagingMobileTestView(tester, const Size(390, 780));
    final harness = MessagingMobileHarness();
    await tester.pumpWidget(
      MessagingMobileTestShell(
        environment: messagingMobileEnvironment(width: 390, height: 780),
        activeDestination: ClientSection.agents,
        content: MessagingMobileFixtureContent(harness),
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
}
