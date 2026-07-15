import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_client/src/contracts/presentation/layout_environment.dart';
import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';

import './bubble_mobile_test_harness.dart';

void main() {
  testWidgets('compact uses a contextual overlay with semantic navigation', (
    tester,
  ) async {
    final harness = BubbleMobileHarness();
    await pumpBubbleMobileHarness(
      tester,
      harness: harness,
      environment: bubbleMobileEnvironment(),
    );

    expect(
      find.byKey(const Key('bubble-mobile-compact-shell')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('bubble-mobile-medium-rail')), findsNothing);
    expect(
      find.byKey(const Key('bubble-mobile-navigation-overlay')),
      findsNothing,
    );

    await tester.tap(find.byKey(const Key('bubble-mobile-menu-button')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('bubble-mobile-navigation-overlay')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('bubble-mobile-contextual-drawer')),
      findsOneWidget,
    );
    for (final destination in bubbleMobileDestinations) {
      expect(
        find.byKey(
          ValueKey('bubble-mobile-compact-navigation-${destination.name}'),
        ),
        findsOneWidget,
      );
    }

    final agents = find.byKey(
      const ValueKey('bubble-mobile-compact-navigation-agents'),
    );
    expect(tester.getSize(agents).height, greaterThanOrEqualTo(48));
    final semantics = tester.getSemantics(agents);
    expect(semantics.label.split('\n').toSet(), {'Agents'});
    expect(semantics.flagsCollection.isButton, isTrue);
    expect(semantics.flagsCollection.isSelected.toBoolOrNull(), isTrue);

    await tester.tap(
      find.byKey(const ValueKey('bubble-mobile-compact-navigation-feed')),
    );
    await tester.pumpAndSettle();
    expect(harness.selectedDestination, ClientSection.feed);
    expect(
      find.byKey(const Key('bubble-mobile-navigation-overlay')),
      findsNothing,
    );
  });

  testWidgets('medium uses a narrow rail with equivalent destinations', (
    tester,
  ) async {
    final harness = BubbleMobileHarness(
      activeDestination: ClientSection.settings,
    );
    await pumpBubbleMobileHarness(
      tester,
      harness: harness,
      environment: bubbleMobileEnvironment(
        width: 720,
        hasPointer: true,
        hasKeyboard: true,
        hasTouch: false,
      ),
    );

    expect(find.byKey(const Key('bubble-mobile-medium-shell')), findsOneWidget);
    expect(find.byKey(const Key('bubble-mobile-medium-rail')), findsOneWidget);
    expect(find.byKey(const Key('bubble-mobile-menu-button')), findsNothing);
    for (final destination in bubbleMobileDestinations) {
      expect(
        find.byKey(
          ValueKey('bubble-mobile-medium-navigation-${destination.name}'),
        ),
        findsOneWidget,
      );
    }
    final settings = find.byKey(
      const ValueKey('bubble-mobile-medium-navigation-settings'),
    );
    expect(tester.getSize(settings).height, greaterThanOrEqualTo(48));
    expect(
      tester.getSemantics(settings).flagsCollection.isSelected.toBoolOrNull(),
      isTrue,
    );

    await tester.tap(
      find.byKey(const ValueKey('bubble-mobile-medium-navigation-agents')),
    );
    await tester.pump();
    expect(harness.selectedDestination, ClientSection.agents);
  });

  testWidgets('keyboard traversal can focus and activate compact navigation', (
    tester,
  ) async {
    final harness = BubbleMobileHarness();
    await pumpBubbleMobileHarness(
      tester,
      harness: harness,
      environment: bubbleMobileEnvironment(hasTouch: false, hasKeyboard: true),
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    expect(FocusManager.instance.primaryFocus, isNotNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('bubble-mobile-navigation-overlay')),
      findsOneWidget,
    );
  });

  testWidgets('safe and keyboard insets keep composer and navigation clear', (
    tester,
  ) async {
    final harness = BubbleMobileHarness();
    final environment = bubbleMobileEnvironment(
      height: 600,
      safeInsets: LayoutInsets(left: 13, top: 17, right: 11, bottom: 19),
      keyboardInset: 180,
    );
    await pumpBubbleMobileHarness(
      tester,
      harness: harness,
      environment: environment,
    );

    final header = find.byKey(const Key('bubble-mobile-compact-header'));
    expect(tester.getTopLeft(header), const Offset(13, 17));
    final composer = find.byKey(const ValueKey('bubble-fake-composer-agents'));
    expect(tester.getBottomRight(composer).dy, lessThanOrEqualTo(420));

    await tester.tap(find.byKey(const Key('bubble-mobile-menu-button')));
    await tester.pumpAndSettle();
    final barrier = find.byKey(const Key('bubble-mobile-overlay-barrier'));
    expect(tester.getBottomRight(barrier).dy, lessThanOrEqualTo(420));
  });

  testWidgets('compact header and overlay share a bounded scaled extent', (
    tester,
  ) async {
    const cases = [
      (scale: 1.0, extent: 52.0),
      (scale: 2.0, extent: 52.0),
      (scale: 2.2, extent: 54.0),
      (scale: 4.0, extent: 61.0),
    ];

    for (final testCase in cases) {
      final harness = BubbleMobileHarness();
      await pumpBubbleMobileHarness(
        tester,
        harness: harness,
        environment: bubbleMobileEnvironment(
          width: 320,
          height: 420,
          textScale: testCase.scale,
          safeInsets: LayoutInsets(top: 7),
        ),
      );

      final header = find.byKey(const Key('bubble-mobile-compact-header'));
      expect(tester.getSize(header).height, testCase.extent);
      expect(tester.getSize(header).height, inInclusiveRange(52, 64));
      await tester.tap(find.byKey(const Key('bubble-mobile-menu-button')));
      await tester.pumpAndSettle();

      final barrier = find.byKey(const Key('bubble-mobile-overlay-barrier'));
      expect(
        tester.getTopLeft(barrier).dy,
        closeTo(tester.getBottomLeft(header).dy, 0.01),
      );
      expect(tester.takeException(), isNull);

      await tester.tap(find.byKey(const Key('bubble-mobile-menu-button')));
      await tester.pumpAndSettle();
    }
  });

  testWidgets('large text remains overflow-safe in compact and medium', (
    tester,
  ) async {
    final compactHarness = BubbleMobileHarness();
    await pumpBubbleMobileHarness(
      tester,
      harness: compactHarness,
      environment: bubbleMobileEnvironment(
        width: 320,
        height: 420,
        textScale: 2.2,
      ),
    );
    await tester.tap(find.byKey(const Key('bubble-mobile-menu-button')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    final mediumHarness = BubbleMobileHarness();
    await pumpBubbleMobileHarness(
      tester,
      harness: mediumHarness,
      environment: bubbleMobileEnvironment(
        width: 620,
        height: 420,
        textScale: 2.2,
        hasPointer: true,
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion resolves all Bubble shell transitions to zero', (
    tester,
  ) async {
    final harness = BubbleMobileHarness();
    await pumpBubbleMobileHarness(
      tester,
      harness: harness,
      environment: bubbleMobileEnvironment(reducedMotion: true),
    );

    await tester.tap(find.byKey(const Key('bubble-mobile-menu-button')));
    await tester.pump();

    final switcher = tester.widget<AnimatedSwitcher>(
      find.byType(AnimatedSwitcher),
    );
    final rotation = tester.widget<AnimatedRotation>(
      find.byType(AnimatedRotation),
    );
    expect(switcher.duration, Duration.zero);
    expect(rotation.duration, Duration.zero);
    expect(
      find.byKey(const Key('bubble-mobile-navigation-overlay')),
      findsOneWidget,
    );
  });

  testWidgets('compact overlay state restores inside the Bubble namespace', (
    tester,
  ) async {
    final harness = BubbleMobileHarness();
    await pumpBubbleMobileHarness(
      tester,
      harness: harness,
      environment: bubbleMobileEnvironment(),
    );
    await tester.tap(find.byKey(const Key('bubble-mobile-menu-button')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('bubble-mobile-navigation-overlay')),
      findsOneWidget,
    );

    await tester.restartAndRestore();
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('bubble-mobile-navigation-overlay')),
      findsOneWidget,
    );
  });
}
