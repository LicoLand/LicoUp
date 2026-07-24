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
      expect(bg, isNot(colors.primary));
      expect((bg!.a * 255.0).round().clamp(0, 255), lessThan(80));

      expect(find.text('Primary'), findsOneWidget);
      expect(find.text('Glass'), findsOneWidget);
      expect(find.byType(AppleGlassActionButton), findsOneWidget);
    },
  );
}
