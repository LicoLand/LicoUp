import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/shell/dashboard_card_shell.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/shell/dashboard_plain_shell.dart';
import 'package:licoup/src/frontend/shared/messaging/messaging_sidebar_navigation.dart';
import 'package:licoup/src/frontend/shared/ui/lico_ambient_clock.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/shared/layout_palette_projection.dart';
import 'package:licoup/src/frontend/shared/messaging/messaging_filter_chips.dart';
import 'package:licoup/src/frontend/shared/ui/continuous_stroke.dart';
import 'package:licoup/src/frontend/shared/ui/lico_selection_highlight.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

void main() {
  Widget host({
    LicoSelectionTreatment? treatment,
    Brightness brightness = Brightness.dark,
    bool disableAnimations = false,
    required Widget child,
  }) {
    return MaterialApp(
      locale: const Locale('en'),
      supportedLocales: LicoStrings.supportedLocales,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      theme: buildLicoTheme(
        presetId: brightness == Brightness.dark
            ? 'lico-starlit-gold'
            : 'lico-taro-waffle',
        platformBrightness: brightness,
      ),
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: disableAnimations),
        child: Builder(
          builder: (context) => LayoutPaletteScope(
            palette: layoutPaletteFromColors(context.licoColors),
            child: treatment == null
                ? child
                : LicoSelectionTreatmentScope(
                    treatment: treatment,
                    child: child,
                  ),
          ),
        ),
      ),
    );
  }

  testWidgets('the treatment scope defaults to lamp', (tester) async {
    late LicoSelectionTreatment resolved;
    await tester.pumpWidget(
      host(
        child: Builder(
          builder: (context) {
            resolved = LicoSelectionTreatmentScope.of(context);
            return const SizedBox();
          },
        ),
      ),
    );
    expect(resolved, LicoSelectionTreatment.lamp);
  });

  testWidgets('lamp renders the shared highlight painter', (tester) async {
    await tester.pumpWidget(
      host(
        child: const LicoSelectionLight(
          selected: true,
          radius: 12,
          child: SizedBox(width: 200, height: 48),
        ),
      ),
    );
    final paint = tester.widget<CustomPaint>(
      find.descendant(
        of: find.byType(LicoSelectionLight),
        matching: find.byType(CustomPaint),
      ),
    );
    expect(paint.painter, isA<LicoSelectionHighlightPainter>());
    expect(
      find.byWidgetPredicate(
        (w) => w is CustomPaint && w.painter is LicoStarlightHighlightPainter,
      ),
      findsNothing,
    );
  });

  testWidgets('starlight renders its own light, never the lamp painter', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        treatment: LicoSelectionTreatment.starlight,
        child: const LicoSelectionLight(
          selected: true,
          radius: 12,
          child: SizedBox(width: 200, height: 48),
        ),
      ),
    );
    expect(
      find.byWidgetPredicate(
        (w) => w is CustomPaint && w.painter is LicoStarlightHighlightPainter,
      ),
      findsOneWidget,
    );
    expect(
      find.byWidgetPredicate(
        (w) => w is CustomPaint && w.painter is LicoSelectionHighlightPainter,
      ),
      findsNothing,
    );
  });

  testWidgets('bottom axis renders the starlight tab light under its scope', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        treatment: LicoSelectionTreatment.starlight,
        child: const LicoSelectionLight(
          selected: true,
          radius: 12,
          axis: LicoSelectionAxis.bottom,
          child: SizedBox(width: 200, height: 48),
        ),
      ),
    );
    final paint = tester.widget<CustomPaint>(
      find.descendant(
        of: find.byType(LicoSelectionLight),
        matching: find.byType(CustomPaint),
      ),
    );
    expect(paint.painter, isA<LicoStarlightTabHighlightPainter>());
  });

  testWidgets('bottom axis keeps the horizontal lamp by default', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        child: const LicoSelectionLight(
          selected: true,
          radius: 12,
          axis: LicoSelectionAxis.bottom,
          child: SizedBox(width: 200, height: 48),
        ),
      ),
    );
    final paint = tester.widget<CustomPaint>(
      find.descendant(
        of: find.byType(LicoSelectionLight),
        matching: find.byType(CustomPaint),
      ),
    );
    expect(paint.painter, isA<LicoSelectionHighlightPainter>());
    expect(
      (paint.painter! as LicoSelectionHighlightPainter).horizontal,
      isTrue,
    );
  });

  testWidgets('starlight drifts on the ambient clock while motion runs', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        treatment: LicoSelectionTreatment.starlight,
        child: const LicoSelectionLight(
          selected: true,
          radius: 12,
          child: SizedBox(width: 200, height: 48),
        ),
      ),
    );
    await tester.pump();
    expect(LicoAmbientClock.shared.subscriberCount, greaterThanOrEqualTo(1));
    expect(LicoAmbientClock.shared.isRunning, isTrue);
    // No vsync ticker: the row repaints only on ambient-clock ticks.
    final elapsed = LicoAmbientClock.shared.value;
    await tester.pump(LicoMotion.ambientFrame);
    expect(LicoAmbientClock.shared.value, greaterThan(elapsed));
  });

  testWidgets('starlight holds a static pose under reduced motion', (
    tester,
  ) async {
    final subscribersBefore = LicoAmbientClock.shared.subscriberCount;
    await tester.pumpWidget(
      host(
        treatment: LicoSelectionTreatment.starlight,
        disableAnimations: true,
        child: const LicoSelectionLight(
          selected: true,
          radius: 12,
          child: SizedBox(width: 200, height: 48),
        ),
      ),
    );
    await tester.pump();
    // The row never subscribes to the ambient clock under reduced motion.
    expect(LicoAmbientClock.shared.subscriberCount, subscribersBefore);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('starlight filter chip drops the gray rest and the gold rim', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        treatment: LicoSelectionTreatment.starlight,
        child: Center(
          child: MessagingFilterChips<String>(
            options: const [
              MessagingFilterChipOption(
                value: 'all',
                label: 'All',
                key: Key('chip-all'),
              ),
              MessagingFilterChipOption(
                value: 'other',
                label: 'Other',
                key: Key('chip-other'),
              ),
            ],
            selected: 'all',
            onSelected: (_) {},
            semanticLabel: 'filters',
          ),
        ),
      ),
    );

    final palette = tester
        .element(find.byType(MessagingFilterChips<String>))
        .layoutPalette;
    ShapeDecoration decorationOf(Key key) =>
        tester
                .widget<AnimatedContainer>(
                  find.descendant(
                    of: find.byKey(key),
                    matching: find.byType(AnimatedContainer),
                  ),
                )
                .decoration!
            as ShapeDecoration;

    final selected = decorationOf(const Key('chip-all'));
    expect(selected.color, isNull);
    expect(selected.gradient, isA<RadialGradient>());
    final selectedSide = (selected.shape as ContinuousRoundedBorder).side;
    expect(selectedSide.color, isNot(palette.brandBorder));
    expect(selectedSide.color, palette.selectionInk.withValues(alpha: 0.30));

    final resting = decorationOf(const Key('chip-other'));
    expect(resting.color, isNot(palette.surfaceLow));
    expect(resting.color, Colors.transparent);
    expect((resting.shape as ContinuousRoundedBorder).side.color, palette.line);
  });

  testWidgets('lamp filter chip keeps the gray rest and the gold rim', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        child: Center(
          child: MessagingFilterChips<String>(
            options: const [
              MessagingFilterChipOption(
                value: 'all',
                label: 'All',
                key: Key('chip-all'),
              ),
              MessagingFilterChipOption(
                value: 'other',
                label: 'Other',
                key: Key('chip-other'),
              ),
            ],
            selected: 'all',
            onSelected: (_) {},
            semanticLabel: 'filters',
          ),
        ),
      ),
    );

    final palette = tester
        .element(find.byType(MessagingFilterChips<String>))
        .layoutPalette;
    ShapeDecoration decorationOf(Key key) =>
        tester
                .widget<AnimatedContainer>(
                  find.descendant(
                    of: find.byKey(key),
                    matching: find.byType(AnimatedContainer),
                  ),
                )
                .decoration!
            as ShapeDecoration;

    final selected = decorationOf(const Key('chip-all'));
    expect(selected.color, palette.selectedSurface);
    expect(
      (selected.shape as ContinuousRoundedBorder).side.color,
      palette.brandBorder,
    );
    final resting = decorationOf(const Key('chip-other'));
    expect(resting.color, palette.surfaceLow);
  });

  testWidgets('bottom nav marks its selection with the tab light', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        treatment: LicoSelectionTreatment.starlight,
        child: Align(
          alignment: Alignment.bottomCenter,
          child: MessagingSidebarBottomNav(
            current: ClientSection.agents,
            onSelectDestination: (_) {},
          ),
        ),
      ),
    );

    final selected = find.byKey(
      const Key('messaging-sidebar-nav-conversations'),
    );
    expect(
      find.descendant(
        of: selected,
        matching: find.byWidgetPredicate(
          (w) =>
              w is CustomPaint && w.painter is LicoStarlightTabHighlightPainter,
        ),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: selected,
        matching: find.byWidgetPredicate(
          (w) => w is CustomPaint && w.painter is LicoSelectionHighlightPainter,
        ),
      ),
      findsNothing,
    );
    final icon = tester.widget<Icon>(
      find.descendant(of: selected, matching: find.byType(Icon)),
    );
    expect(icon.shadows, hasLength(1));
    expect(icon.shadows!.first.blurRadius, 10);
  });

  test('the plain dashboard picks starlight in dark and lamp in light', () {
    final dark = layoutPaletteFromColors(
      licoColorsFor('lico-starlit-gold', platformBrightness: Brightness.dark),
    );
    final light = layoutPaletteFromColors(
      licoColorsFor('lico-taro-waffle', platformBrightness: Brightness.light),
    );
    expect(
      dashboardPlainSelectionTreatment(dark),
      LicoSelectionTreatment.starlight,
    );
    expect(
      dashboardPlainSelectionTreatment(light),
      LicoSelectionTreatment.lamp,
    );
    expect(
      dashboardCardSelectionTreatment(dark),
      LicoSelectionTreatment.starlight,
    );
    expect(dashboardCardSelectionTreatment(light), LicoSelectionTreatment.lamp);
  });
}
