import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/frontend/shared/ui/apple_glass.dart';
import 'package:licoup/src/frontend/shared/ui/apple_notifications.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

void main() {
  testWidgets('apple glass snackbar uses floating glass chrome', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLicoTheme(platformBrightness: Brightness.dark),
        home: Scaffold(
          body: Builder(
            builder: (context) {
              return TextButton(
                onPressed: () {
                  ScaffoldMessenger.of(context).showSnackBar(
                    appleGlassSnackBar(context: context, message: 'Copied'),
                  );
                },
                child: const Text('Show'),
              );
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('Show'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byKey(const Key('apple-glass-snackbar')), findsOneWidget);
    expect(find.byType(AppleGlassSurface), findsOneWidget);
    expect(find.text('Copied'), findsOneWidget);
  });

  testWidgets(
    'apple glass notice banner keeps warning tone without solid fill',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildLicoTheme(platformBrightness: Brightness.dark),
          home: const Scaffold(
            body: AppleGlassNoticeBanner(
              message: 'Native history is read-only',
              tone: AppleGlassNoticeTone.warning,
              messageKey: Key('notice-message'),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byKey(const Key('notice-message')), findsOneWidget);
      final decorated = tester.widget<DecoratedBox>(
        find.byType(DecoratedBox).first,
      );
      final decoration = decorated.decoration as BoxDecoration;
      expect(decoration.border?.top.width, lessThan(1.1));
    },
  );
}
