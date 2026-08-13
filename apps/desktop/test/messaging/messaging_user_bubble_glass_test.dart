import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_user_bubble_glass.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/tokens/messaging_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

void main() {
  group('MessagingDesktopMetrics userBubbleGlass', () {
    test('fill is fully transparent', () {
      final darkFill = MessagingDesktopMetrics.userBubbleGlassFill(
        isDark: true,
      );
      final lightFill = MessagingDesktopMetrics.userBubbleGlassFill(
        isDark: false,
      );

      expect(darkFill.alpha, 0);
      expect(lightFill.alpha, 0);
    });

    test('border tints neutral line, not brand', () {
      const line = Color(0xFF888888);
      const brandBorder = Color(0xFFd4e157);
      final border = MessagingDesktopMetrics.userBubbleGlassBorder(
        line,
        isDark: true,
      );

      expect(border.red, line.red);
      expect(border.green, line.green);
      expect(border.blue, line.blue);
      expect(border, isNot(equals(brandBorder.withAlpha(border.alpha))));
      expect(
        border.alpha,
        MessagingDesktopMetrics.userBubbleGlassBorderAlphaDark,
      );
    });

    test('blur sigma matches conversation overlay glass', () {
      expect(
        MessagingDesktopMetrics.userBubbleGlassBlurSigma,
        MessagingDesktopMetrics.conversationOverlayGlassBlurSigma,
      );
    });
  });

  testWidgets('user bubble has no brand glow and no brand rim', (tester) async {
    final theme = buildLicoTheme(platformBrightness: Brightness.dark);
    final colors = theme.extension<LicoThemeColors>()!;

    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(
          body: Center(
            child: MessagingUserBubbleGlass(
              borderRadius: BorderRadius.circular(12),
              padding: const EdgeInsets.all(12),
              child: const Text('hello'),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(BackdropFilter), findsOneWidget);

    final animated = tester.widget<AnimatedContainer>(
      find.descendant(
        of: find.byType(MessagingUserBubbleGlass),
        matching: find.byType(AnimatedContainer),
      ),
    );
    final decoration = animated.decoration! as BoxDecoration;
    expect(decoration.color!.alpha, 0);
    expect(decoration.boxShadow ?? const <BoxShadow>[], isEmpty);
    expect(decoration.border, isNotNull);
    final borderColor = decoration.border!.top.color;
    expect(borderColor.red, colors.line.red);
    expect(borderColor.green, colors.line.green);
    expect(borderColor.blue, colors.line.blue);
    expect(borderColor, isNot(equals(colors.brandBorder)));
    expect(borderColor, isNot(equals(colors.primary)));
    expect(tester.takeException(), isNull);
  });
}
