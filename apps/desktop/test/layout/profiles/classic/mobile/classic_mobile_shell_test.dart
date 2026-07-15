import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_client/src/contracts/presentation/layout_environment.dart';
import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';

import './classic_mobile_test_harness.dart';

void main() {
  testWidgets('compact uses contextual card navigation with semantics', (
    tester,
  ) async {
    final harness = ClassicMobileHarness();
    await pumpClassicMobileHarness(
      tester,
      harness: harness,
      environment: classicMobileEnvironment(),
    );

    expect(
      find.byKey(const Key('classic-mobile-compact-shell')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('classic-mobile-compact-card-stack')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('classic-mobile-medium-card-stack')),
      findsNothing,
    );
    expect(find.text('Agents'), findsAtLeastNWidgets(1));

    await tester.tap(
      find.byKey(const Key('classic-mobile-compact-navigation-trigger')),
    );
    await tester.pumpAndSettle();
    for (final destination in classicMobileDestinations) {
      expect(
        find.byKey(
          ValueKey<String>(
            'classic-mobile-compact-navigation-${destination.name}',
          ),
        ),
        findsOneWidget,
      );
    }
    final agents = find.byKey(
      const Key('classic-mobile-compact-navigation-agents'),
    );
    expect(tester.getSize(agents).height, greaterThanOrEqualTo(56));
    expect(
      tester.getSemantics(agents).flagsCollection.isSelected.toBoolOrNull(),
      isTrue,
    );

    await tester.tap(
      find.byKey(const Key('classic-mobile-compact-navigation-feed')),
    );
    await tester.pumpAndSettle();
    expect(harness.selectedDestination, ClientSection.feed);
  });

  testWidgets('medium uses persistent navigation with equivalent targets', (
    tester,
  ) async {
    final harness = ClassicMobileHarness(
      activeDestination: ClientSection.settings,
    );
    await pumpClassicMobileHarness(
      tester,
      harness: harness,
      environment: classicMobileEnvironment(
        width: 720,
        hasPointer: true,
        hasKeyboard: true,
        hasTouch: false,
      ),
    );

    expect(
      find.byKey(const Key('classic-mobile-medium-shell')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('classic-mobile-medium-card-stack')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('classic-mobile-compact-card-stack')),
      findsNothing,
    );
    for (final destination in classicMobileDestinations) {
      expect(
        find.byKey(
          ValueKey<String>(
            'classic-mobile-medium-navigation-${destination.name}',
          ),
        ),
        findsOneWidget,
      );
    }
    final settings = find.byKey(
      const Key('classic-mobile-medium-navigation-settings'),
    );
    expect(tester.getSize(settings).height, greaterThanOrEqualTo(56));
    expect(
      tester.getSemantics(settings).flagsCollection.isSelected.toBoolOrNull(),
      isTrue,
    );

    await tester.tap(
      find.byKey(const Key('classic-mobile-medium-navigation-agents')),
    );
    await tester.pump();
    expect(harness.selectedDestination, ClientSection.agents);
  });

  testWidgets('keyboard traversal reaches compact navigation', (tester) async {
    final harness = ClassicMobileHarness();
    await pumpClassicMobileHarness(
      tester,
      harness: harness,
      environment: classicMobileEnvironment(hasTouch: false, hasKeyboard: true),
    );

    for (var step = 0; step < 4; step++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      expect(FocusManager.instance.primaryFocus, isNotNull);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      if (find
          .byKey(const Key('classic-mobile-compact-navigation-feed'))
          .evaluate()
          .isNotEmpty) {
        break;
      }
    }
    expect(
      find.byKey(const Key('classic-mobile-compact-navigation-feed')),
      findsOneWidget,
    );
  });

  testWidgets('safe and keyboard insets preserve the destination clearance', (
    tester,
  ) async {
    final harness = ClassicMobileHarness();
    final environment = classicMobileEnvironment(
      height: 600,
      safeInsets: LayoutInsets(left: 13, top: 17, right: 11, bottom: 19),
      keyboardInset: 180,
    );
    await pumpClassicMobileHarness(
      tester,
      harness: harness,
      environment: environment,
    );

    final navigation = find.byKey(
      const Key('classic-mobile-compact-contextual-navigation'),
    );
    expect(tester.getTopLeft(navigation), const Offset(29, 25));
    final clearance = tester.widget<AnimatedPadding>(
      find.byKey(const Key('classic-mobile-composer-clearance')),
    );
    expect((clearance.padding as EdgeInsets).bottom, 192);
    expect(tester.takeException(), isNull);
  });

  testWidgets('large text remains bounded in compact and medium', (
    tester,
  ) async {
    final compact = ClassicMobileHarness();
    await pumpClassicMobileHarness(
      tester,
      harness: compact,
      environment: classicMobileEnvironment(
        width: 390,
        height: 620,
        textScale: 3,
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    final medium = ClassicMobileHarness();
    await pumpClassicMobileHarness(
      tester,
      harness: medium,
      environment: classicMobileEnvironment(
        width: 720,
        height: 620,
        textScale: 3,
        hasPointer: true,
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion resolves the shell clearance animation to zero', (
    tester,
  ) async {
    final harness = ClassicMobileHarness();
    await pumpClassicMobileHarness(
      tester,
      harness: harness,
      environment: classicMobileEnvironment(reducedMotion: true),
    );

    final clearance = tester.widget<AnimatedPadding>(
      find.byKey(const Key('classic-mobile-composer-clearance')),
    );
    expect(clearance.duration, Duration.zero);
    expect(tester.takeException(), isNull);
  });

  testWidgets('light and dark themes preserve the same content adapter', (
    tester,
  ) async {
    final light = ClassicMobileHarness();
    await pumpClassicMobileHarness(
      tester,
      harness: light,
      environment: classicMobileEnvironment(),
    );
    expect(light.content.brightnesses.last, Brightness.light);

    final dark = ClassicMobileHarness();
    await pumpClassicMobileHarness(
      tester,
      harness: dark,
      environment: classicMobileEnvironment(),
      brightness: Brightness.dark,
    );
    expect(dark.content.brightnesses.last, Brightness.dark);
    expect(tester.takeException(), isNull);
  });
}
