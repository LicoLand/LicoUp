import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_client/src/contracts/presentation/layout_environment.dart';
import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';

import './studio_mobile_test_harness.dart';

void main() {
  testWidgets('compact uses a contextual overlay with semantic navigation', (
    tester,
  ) async {
    final harness = StudioMobileHarness();
    await pumpStudioMobileHarness(
      tester,
      harness: harness,
      environment: studioMobileEnvironment(),
    );

    expect(
      find.byKey(const Key('studio-mobile-compact-shell')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('studio-mobile-medium-rail')), findsNothing);
    expect(
      find.byKey(const Key('studio-mobile-navigation-overlay')),
      findsNothing,
    );

    await tester.tap(find.byKey(const Key('studio-mobile-menu-button')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('studio-mobile-navigation-overlay')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('studio-mobile-contextual-drawer')),
      findsOneWidget,
    );
    for (final destination in studioMobileDestinations) {
      expect(
        find.byKey(
          ValueKey('studio-mobile-compact-navigation-${destination.name}'),
        ),
        findsOneWidget,
      );
    }

    final agents = find.byKey(
      const ValueKey('studio-mobile-compact-navigation-agents'),
    );
    expect(tester.getSize(agents).height, greaterThanOrEqualTo(48));
    final semantics = tester.getSemantics(agents);
    expect(semantics.label.split('\n').toSet(), {'Agents'});
    expect(semantics.flagsCollection.isButton, isTrue);
    expect(semantics.flagsCollection.isSelected.toBoolOrNull(), isTrue);

    await tester.tap(
      find.byKey(const ValueKey('studio-mobile-compact-navigation-feed')),
    );
    await tester.pumpAndSettle();
    expect(harness.selectedDestination, ClientSection.feed);
    expect(
      find.byKey(const Key('studio-mobile-navigation-overlay')),
      findsNothing,
    );
  });

  testWidgets('medium uses a narrow rail with equivalent destinations', (
    tester,
  ) async {
    final harness = StudioMobileHarness(
      activeDestination: ClientSection.settings,
    );
    await pumpStudioMobileHarness(
      tester,
      harness: harness,
      environment: studioMobileEnvironment(
        width: 720,
        hasPointer: true,
        hasKeyboard: true,
        hasTouch: false,
      ),
    );

    expect(find.byKey(const Key('studio-mobile-medium-shell')), findsOneWidget);
    expect(find.byKey(const Key('studio-mobile-medium-rail')), findsOneWidget);
    expect(find.byKey(const Key('studio-mobile-menu-button')), findsNothing);
    for (final destination in studioMobileDestinations) {
      expect(
        find.byKey(
          ValueKey('studio-mobile-medium-navigation-${destination.name}'),
        ),
        findsOneWidget,
      );
    }
    final settings = find.byKey(
      const ValueKey('studio-mobile-medium-navigation-settings'),
    );
    expect(tester.getSize(settings).height, greaterThanOrEqualTo(48));
    expect(
      tester.getSemantics(settings).flagsCollection.isSelected.toBoolOrNull(),
      isTrue,
    );

    await tester.tap(
      find.byKey(const ValueKey('studio-mobile-medium-navigation-agents')),
    );
    await tester.pump();
    expect(harness.selectedDestination, ClientSection.agents);
  });

  testWidgets('keyboard traversal can focus and activate compact navigation', (
    tester,
  ) async {
    final harness = StudioMobileHarness();
    await pumpStudioMobileHarness(
      tester,
      harness: harness,
      environment: studioMobileEnvironment(hasTouch: false, hasKeyboard: true),
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    expect(FocusManager.instance.primaryFocus, isNotNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('studio-mobile-navigation-overlay')),
      findsOneWidget,
    );
  });

  testWidgets('safe and keyboard insets keep composer and navigation clear', (
    tester,
  ) async {
    final harness = StudioMobileHarness();
    final environment = studioMobileEnvironment(
      height: 600,
      safeInsets: LayoutInsets(left: 13, top: 17, right: 11, bottom: 19),
      keyboardInset: 180,
    );
    await pumpStudioMobileHarness(
      tester,
      harness: harness,
      environment: environment,
    );

    final header = find.byKey(const Key('studio-mobile-compact-header'));
    expect(tester.getTopLeft(header), const Offset(13, 17));
    final composer = find.byKey(const ValueKey('studio-fake-composer-agents'));
    expect(tester.getBottomRight(composer).dy, lessThanOrEqualTo(420));

    await tester.tap(find.byKey(const Key('studio-mobile-menu-button')));
    await tester.pumpAndSettle();
    final barrier = find.byKey(const Key('studio-mobile-overlay-barrier'));
    expect(tester.getBottomRight(barrier).dy, lessThanOrEqualTo(420));
  });

  testWidgets('large text remains overflow-safe in compact and medium', (
    tester,
  ) async {
    final compactHarness = StudioMobileHarness();
    await pumpStudioMobileHarness(
      tester,
      harness: compactHarness,
      environment: studioMobileEnvironment(
        width: 320,
        height: 420,
        textScale: 2,
      ),
    );
    await tester.tap(find.byKey(const Key('studio-mobile-menu-button')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    final mediumHarness = StudioMobileHarness();
    await pumpStudioMobileHarness(
      tester,
      harness: mediumHarness,
      environment: studioMobileEnvironment(
        width: 620,
        height: 420,
        textScale: 2,
        hasPointer: true,
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion resolves all Studio shell transitions to zero', (
    tester,
  ) async {
    final harness = StudioMobileHarness();
    await pumpStudioMobileHarness(
      tester,
      harness: harness,
      environment: studioMobileEnvironment(reducedMotion: true),
    );

    await tester.tap(find.byKey(const Key('studio-mobile-menu-button')));
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
      find.byKey(const Key('studio-mobile-navigation-overlay')),
      findsOneWidget,
    );
  });

  testWidgets('compact overlay state restores inside the Studio namespace', (
    tester,
  ) async {
    final harness = StudioMobileHarness();
    await pumpStudioMobileHarness(
      tester,
      harness: harness,
      environment: studioMobileEnvironment(),
    );
    await tester.tap(find.byKey(const Key('studio-mobile-menu-button')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('studio-mobile-navigation-overlay')),
      findsOneWidget,
    );

    await tester.restartAndRestore();
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('studio-mobile-navigation-overlay')),
      findsOneWidget,
    );
  });
}
