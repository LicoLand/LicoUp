import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_user_bubble_glass.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/tokens/messaging_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

int _alpha8(Color color) => (color.toARGB32() >> 24) & 0xff;
int _red8(Color color) => (color.toARGB32() >> 16) & 0xff;
int _green8(Color color) => (color.toARGB32() >> 8) & 0xff;
int _blue8(Color color) => color.toARGB32() & 0xff;

void main() {
  group('MessagingDesktopMetrics userBubbleGlass', () {
    test('fill is fully transparent', () {
      final darkFill = MessagingDesktopMetrics.userBubbleGlassFill(
        isDark: true,
      );
      final lightFill = MessagingDesktopMetrics.userBubbleGlassFill(
        isDark: false,
      );

      expect(_alpha8(darkFill), 0);
      expect(_alpha8(lightFill), 0);
    });

    test('border tints neutral line, not brand', () {
      const line = Color(0xFF888888);
      const brandBorder = Color(0xFFd4e157);
      final border = MessagingDesktopMetrics.userBubbleGlassBorder(
        line,
        isDark: true,
      );

      expect(_red8(border), _red8(line));
      expect(_green8(border), _green8(line));
      expect(_blue8(border), _blue8(line));
      expect(border, isNot(equals(brandBorder.withAlpha(_alpha8(border)))));
      expect(
        _alpha8(border),
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
    expect(_alpha8(decoration.color!), 0);
    expect(decoration.boxShadow ?? const <BoxShadow>[], isEmpty);
    expect(decoration.border, isNotNull);
    final borderColor = decoration.border!.top.color;
    expect(_red8(borderColor), _red8(colors.line));
    expect(_green8(borderColor), _green8(colors.line));
    expect(_blue8(borderColor), _blue8(colors.line));
    expect(borderColor, isNot(equals(colors.brandBorder)));
    expect(borderColor, isNot(equals(colors.primary)));
    expect(tester.takeException(), isNull);
  });
}
