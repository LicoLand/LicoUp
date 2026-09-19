import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/frontend/shared/ui/apple_control_metrics.dart';
import 'package:licoup/src/frontend/shared/ui/apple_glass.dart';
import 'package:licoup/src/frontend/shared/ui/apple_popup_select.dart';
import 'package:licoup/src/frontend/shared/ui/continuous_stroke.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

void main() {
  testWidgets('ApplePopupSelect uses glass control and brand-yellow focus', (
    tester,
  ) async {
    String? selected = 'a';
    final theme = buildLicoTheme(
      platformBrightness: Brightness.dark,
    ).copyWith(platform: TargetPlatform.macOS);
    final brandGold = theme.extension<LicoThemeColors>()!.primaryStrong;

    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 220,
              child: StatefulBuilder(
                builder: (context, setState) {
                  return ApplePopupSelect<String>(
                    key: const Key('apple-popup-select'),
                    value: selected,
                    isExpanded: true,
                    options: const [
                      ApplePopupSelectOption(value: 'a', label: 'Alpha'),
                      ApplePopupSelectOption(value: 'b', label: 'Beta'),
                      ApplePopupSelectOption(value: 'c', label: 'Gamma'),
                    ],
                    onChanged: (value) => setState(() => selected = value),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Alpha'), findsOneWidget);
    expect(find.byType(AppleGlassSurface), findsOneWidget);
    expect(find.byType(DropdownButton<String>), findsNothing);

    await tester.tap(find.byKey(const Key('apple-popup-select')));
    await tester.pumpAndSettle();

    final focusedSurface = tester.widget<AppleGlassSurface>(
      find.descendant(
        of: find.byKey(const Key('apple-popup-select')),
        matching: find.byType(AppleGlassSurface),
      ),
    );
    expect(focusedSurface.focused, isTrue);
    expect(focusedSurface.focusColor, brandGold);

    final focusedDecoration = tester.widget<DecoratedBox>(
      find.descendant(
        of: find.byKey(const Key('apple-popup-select')),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is DecoratedBox &&
              widget.decoration is ShapeDecoration &&
              (widget.decoration as ShapeDecoration).shape
                  is ContinuousRoundedBorder &&
              ((widget.decoration as ShapeDecoration).shape
                          as ContinuousRoundedBorder)
                      .side
                      .style ==
                  BorderStyle.solid,
        ),
      ),
    );
    expect(focusedDecoration.position, DecorationPosition.foreground);
    final stroke =
        (focusedDecoration.decoration as ShapeDecoration).shape
            as ContinuousRoundedBorder;
    // The focus ring is drawn at full strength: a translucent one-pixel color
    // shift is not a reliable focus signal, so the ring is opaque and wider.
    expect(stroke.side.color, brandGold);
    expect(stroke.side.width, AppleControlMetrics.searchFocusRingWidth);
    expect(stroke.side.color, isNot(kAppleMenuSelectionBlue));

    expect(find.text('Beta'), findsOneWidget);
    expect(find.byIcon(Icons.check), findsOneWidget);

    await tester.tap(find.text('Beta'));
    await tester.pumpAndSettle();
    expect(selected, 'b');
    expect(find.text('Beta'), findsOneWidget);
    expect(find.text('Gamma'), findsNothing);
  });

  testWidgets('ApplePopupSelectField keeps label above the control', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLicoTheme(platformBrightness: Brightness.dark),
        home: Scaffold(
          body: ApplePopupSelectField<String>(
            label: 'Model',
            value: 'm1',
            options: const [
              ApplePopupSelectOption(value: 'm1', label: 'Model One'),
              ApplePopupSelectOption(value: 'm2', label: 'Model Two'),
            ],
            onChanged: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Model'), findsOneWidget);
    expect(find.text('Model One'), findsOneWidget);
    expect(find.byType(ApplePopupSelect<String>), findsOneWidget);
  });
}
