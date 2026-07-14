import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_client/src/contracts/presentation/layout_environment.dart';
import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/layout/layout_surface_bundle.dart';
import 'package:flutter_client/src/frontend/layout/profiles/workbench/mobile/workbench_mobile_bundle.dart';

import './workbench_mobile_test_fakes.dart';

void main() {
  group('workbench mobile shell', () {
    testWidgets(
      'compact uses contextual navigation with selected semantics and actions',
      (tester) async {
        final selections = <ClientSection>[];
        final content = FakeWorkbenchDestinationContent();
        await _pumpWorkbenchShell(
          tester,
          size: const Size(390, 760),
          activeDestination: ClientSection.agents,
          content: content,
          onSelectDestination: selections.add,
          hasTouch: true,
          hasKeyboard: true,
        );

        expect(
          find.byKey(
            const ValueKey('workbench-mobile-compact-contextual-navigation'),
          ),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('workbench-mobile-compact-card-stack')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('workbench-mobile-medium-card-stack')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('fake-workbench-mobile-content-agents')),
          findsOneWidget,
        );
        expect(content.builds, contains(ClientSection.agents));

        final trigger = find.byKey(
          const ValueKey('workbench-mobile-compact-navigation-trigger'),
        );
        expect(tester.getSize(trigger).shortestSide, greaterThanOrEqualTo(48));
        await tester.tap(trigger);
        await tester.pumpAndSettle();

        final selectedItem = find.byKey(
          const ValueKey('workbench-mobile-compact-navigation-agents'),
        );
        final selectedSemantics = tester.getSemantics(selectedItem);
        expect(
          selectedSemantics.flagsCollection.isSelected,
          ui.Tristate.isTrue,
        );

        final feedItem = find.byKey(
          const ValueKey('workbench-mobile-compact-navigation-feed'),
        );
        expect(tester.getSize(feedItem).height, greaterThanOrEqualTo(56));
        await tester.tap(feedItem);
        await tester.pumpAndSettle();

        expect(selections, [ClientSection.feed]);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('medium uses a side card stack with focusable touch targets', (
      tester,
    ) async {
      final selections = <ClientSection>[];
      final content = FakeWorkbenchDestinationContent();
      await _pumpWorkbenchShell(
        tester,
        size: const Size(720, 760),
        activeDestination: ClientSection.settings,
        content: content,
        onSelectDestination: selections.add,
        hasTouch: true,
        hasKeyboard: true,
        hasPointer: true,
      );

      final navigation = find.byKey(
        const ValueKey('workbench-mobile-medium-contextual-navigation'),
      );
      final destinationPanel = find.byKey(
        const ValueKey('workbench-mobile-medium-destination-panel'),
      );
      expect(navigation, findsOneWidget);
      expect(destinationPanel, findsOneWidget);
      expect(
        tester.getRect(navigation).right,
        lessThan(tester.getRect(destinationPanel).left),
      );

      for (final destination in workbenchMobileTestDestinations) {
        final item = find.byKey(
          ValueKey<String>(
            'workbench-mobile-medium-navigation-${destination.name}',
          ),
        );
        expect(item, findsOneWidget);
        expect(tester.getSize(item).height, greaterThanOrEqualTo(56));
      }

      final selectedItem = find.byKey(
        const ValueKey('workbench-mobile-medium-navigation-settings'),
      );
      final selectedSemantics = tester.getSemantics(selectedItem);
      expect(selectedSemantics.flagsCollection.isButton, isTrue);
      expect(selectedSemantics.flagsCollection.isSelected, ui.Tristate.isTrue);
      final focusableInk = tester.widget<InkWell>(
        find.descendant(of: selectedItem, matching: find.byType(InkWell)),
      );
      expect(focusableInk.onTap, isNotNull);
      expect(focusableInk.focusColor, isNotNull);

      await tester.tap(
        find.byKey(const ValueKey('workbench-mobile-medium-navigation-feed')),
      );
      await tester.pump();
      expect(selections, [ClientSection.feed]);
      expect(
        find.byKey(const ValueKey('fake-workbench-mobile-content-settings')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'safe and keyboard insets reserve composer space and disable motion',
      (tester) async {
        final scheme = ColorScheme.fromSeed(
          seedColor: const Color(0xff7251a8),
          brightness: Brightness.dark,
        );
        await _pumpWorkbenchShell(
          tester,
          size: const Size(390, 760),
          activeDestination: ClientSection.agents,
          content: FakeWorkbenchDestinationContent(),
          onSelectDestination: (_) {},
          colorScheme: scheme,
          textScale: 2.2,
          safeInsets: LayoutInsets(left: 8, top: 24, right: 10, bottom: 34),
          keyboardInset: 280,
          reducedMotion: true,
          hasTouch: true,
        );

        final clearance = tester.widget<AnimatedPadding>(
          find.byKey(const ValueKey('workbench-mobile-composer-clearance')),
        );
        expect(clearance.padding, const EdgeInsets.only(bottom: 292));
        expect(clearance.duration, Duration.zero);

        final shell = find.byKey(
          const ValueKey('workbench-mobile-compact-shell'),
        );
        expect(tester.widget<ColoredBox>(shell).color, scheme.surface);
        expect(tester.getTopLeft(shell).dx, 0);
        expect(
          tester
              .getTopLeft(
                find.byKey(
                  const ValueKey('workbench-mobile-compact-card-stack'),
                ),
              )
              .dy,
          greaterThanOrEqualTo(32),
        );

        final navigationMaterial = tester.widget<Material>(
          find.byKey(
            const ValueKey('workbench-mobile-compact-contextual-navigation'),
          ),
        );
        final destinationMaterial = tester.widget<Material>(
          find.byKey(
            const ValueKey('workbench-mobile-compact-destination-panel'),
          ),
        );
        expect(navigationMaterial.color, scheme.surfaceContainerLow);
        expect(destinationMaterial.color, scheme.surfaceContainerLowest);

        final mediaQueries = tester.widgetList<MediaQuery>(
          find.byType(MediaQuery),
        );
        expect(
          mediaQueries.any(
            (query) =>
                query.data.disableAnimations &&
                query.data.textScaler.scale(10) == 22,
          ),
          isTrue,
        );
        final restorationIds = tester
            .widgetList<RestorationScope>(find.byType(RestorationScope))
            .map((scope) => scope.restorationId)
            .toSet();
        expect(restorationIds, contains('workbench.mobile.compact.shell'));
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('compact and medium resist long-label text scaling overflow', (
      tester,
    ) async {
      String longLabel(ClientSection destination) =>
          'Extended ${destination.name} workspace destination';

      await _pumpWorkbenchShell(
        tester,
        size: const Size(320, 560),
        activeDestination: ClientSection.mobileRelay,
        content: FakeWorkbenchDestinationContent(),
        onSelectDestination: (_) {},
        destinationLabel: longLabel,
        textScale: 2.4,
        hasTouch: true,
      );
      await tester.tap(
        find.byKey(
          const ValueKey('workbench-mobile-compact-navigation-trigger'),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(
          const ValueKey('workbench-mobile-compact-navigation-settings'),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);

      await _pumpWorkbenchShell(
        tester,
        size: const Size(600, 560),
        activeDestination: ClientSection.mobileRelay,
        content: FakeWorkbenchDestinationContent(),
        onSelectDestination: (_) {},
        destinationLabel: longLabel,
        textScale: 2,
        hasTouch: true,
      );
      expect(
        find.byKey(const ValueKey('workbench-mobile-medium-navigation-scroll')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  });
}

Future<void> _pumpWorkbenchShell(
  WidgetTester tester, {
  required Size size,
  required ClientSection activeDestination,
  required FakeWorkbenchDestinationContent content,
  required ValueChanged<ClientSection> onSelectDestination,
  ColorScheme? colorScheme,
  String Function(ClientSection)? destinationLabel,
  double textScale = 1,
  LayoutInsets safeInsets = LayoutInsets.zero,
  double keyboardInset = 0,
  bool reducedMotion = false,
  bool hasTouch = false,
  bool hasKeyboard = false,
  bool hasPointer = false,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);

  final environment = LayoutEnvironment.fromConstraints(
    surface: LayoutRuntimeSurface.mobile,
    width: size.width,
    height: size.height,
    textScale: textScale,
    safeInsets: safeInsets,
    keyboardInset: keyboardInset,
    reducedMotion: reducedMotion,
    hasTouch: hasTouch,
    hasKeyboard: hasKeyboard,
    hasPointer: hasPointer,
  );
  final variant = workbenchMobileBundle.variants[environment.viewport]!;
  final scheme =
      colorScheme ?? ColorScheme.fromSeed(seedColor: const Color(0xff365f8d));

  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      restorationScopeId: 'workbench-mobile-test',
      theme: ThemeData(useMaterial3: true, colorScheme: scheme),
      home: Builder(
        builder: (context) {
          final destination = content.buildDestination(
            context,
            activeDestination,
          );
          return variant.shellBuilder(
            context,
            LayoutShellBuildContext(
              environment: environment,
              activeDestination: activeDestination,
              availableDestinations: workbenchMobileTestDestinations,
              destination: destination,
              onSelectDestination: onSelectDestination,
              destinationLabel: destinationLabel ?? workbenchMobileTestLabel,
              components: workbenchMobileBundle.components,
              tokens: workbenchMobileBundle.tokens,
              initialFocusTarget: 'conversation-composer',
            ),
          );
        },
      ),
    ),
  );
  await tester.pumpAndSettle();
}
