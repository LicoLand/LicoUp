import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/frontend/shared/ui/apple_buttons.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

void main() {
  testWidgets(
    'theme filled buttons use glass style instead of solid brand gold',
    (tester) async {
      final theme = buildLicoTheme(platformBrightness: Brightness.dark);
      final colors = theme.extension<LicoThemeColors>()!;

      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            body: Column(
              children: [
                FilledButton(onPressed: () {}, child: const Text('Primary')),
                OutlinedButton(
                  onPressed: () {},
                  child: const Text('Secondary'),
                ),
                AppleGlassActionButton(
                  label: 'Glass',
                  icon: Icons.download_rounded,
                  onPressed: () {},
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();

      final filledStyle = theme.filledButtonTheme.style!;
      final bg = filledStyle.backgroundColor!.resolve({});
      // Lemon is a fill-and-mark role reserved for the single most important
      // action in a view, so the default filled button must not claim it.
      expect(bg, isNot(colors.primary));
      expect(bg, isNot(colors.primaryStrong));
      // It resolves to a neutral surface role rather than a white alpha wash,
      // so a preset with an unusual background is not given a foreign haze.
      expect(bg, colors.surfaceRaised);

      // Pressed and hovered are state washes composited over that surface.
      final pressed = filledStyle.backgroundColor!.resolve({
        WidgetState.pressed,
      });
      expect(pressed, isNot(bg));

      final disabled = filledStyle.backgroundColor!.resolve({
        WidgetState.disabled,
      });
      expect(disabled!.a, lessThan(1.0));

      // The rim comes from the line role, not from white alpha.
      expect(filledStyle.side!.resolve({})!.color, colors.line);

      expect(find.text('Primary'), findsOneWidget);
      expect(find.text('Glass'), findsOneWidget);
      expect(find.byType(AppleGlassActionButton), findsOneWidget);
    },
  );
}
