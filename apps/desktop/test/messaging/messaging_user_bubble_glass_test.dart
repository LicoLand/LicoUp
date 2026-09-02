import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_bubble_edge_glow.dart';
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

    test('edge light band tints accent, never neutral line or brand', () {
      const accentGlow = Color(0x38007d8a);
      const line = Color(0xFF888888);
      const brandGlow = Color(0xFFd4e157);
      final band =
          MessagingDesktopMetrics.bubbleEdgeGlowBand(accentGlow, isDark: true)
              as LinearGradient;
      final top = band.colors.first;
      final bottom = band.colors.last;

      expect(_red8(top), _red8(accentGlow));
      expect(_green8(top), _green8(accentGlow));
      expect(_blue8(top), _blue8(accentGlow));
      expect(_alpha8(top), MessagingDesktopMetrics.bubbleEdgeGlowAlphaDark);
      expect(
        _alpha8(bottom),
        MessagingDesktopMetrics.bubbleEdgeGlowDimAlphaDark,
      );
      expect(_alpha8(top), greaterThan(_alpha8(bottom)));
      expect(top, isNot(equals(line.withAlpha(_alpha8(top)))));
      expect(top, isNot(equals(brandGlow.withAlpha(_alpha8(top)))));
    });

    test('blur sigma matches conversation overlay glass', () {
      expect(
        MessagingDesktopMetrics.userBubbleGlassBlurSigma,
        MessagingDesktopMetrics.conversationOverlayGlassBlurSigma,
      );
    });
  });

  testWidgets('user bubble carries light on the rim, not in the fill', (
    tester,
  ) async {
    final theme = buildLicoTheme(platformBrightness: Brightness.dark);

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

    final glowPaint = tester.widget<CustomPaint>(
      find.descendant(
        of: find.byType(MessagingBubbleEdgeGlow),
        matching: find.byType(CustomPaint),
      ),
    );
    final painter = glowPaint.painter! as MessagingBubbleEdgeGlowPainter;
    expect(painter.strokeWidth, MessagingDesktopMetrics.bubbleEdgeRimWidth);
    final rimGradient = painter.rimGradient as LinearGradient;
    // The default bubble light is white; agent brand hues resolve per target.
    expect(_red8(rimGradient.colors.first), 255);
    expect(_green8(rimGradient.colors.first), 255);
    expect(_blue8(rimGradient.colors.first), 255);
    expect(
      _alpha8(rimGradient.colors.first),
      MessagingDesktopMetrics.bubbleEdgeGlowAlphaDark,
    );
    // The field decays with distance: each pass is softer than the one
    // closer to the rim.
    final nearGradient = painter.nearGradient as LinearGradient;
    final midGradient = painter.midGradient as LinearGradient;
    final farGradient = painter.farGradient as LinearGradient;
    expect(
      _alpha8(nearGradient.colors.first),
      MessagingDesktopMetrics.bubbleEdgeGlowNearAlphaDark,
    );
    expect(
      _alpha8(nearGradient.colors.first),
      lessThan(_alpha8(rimGradient.colors.first)),
    );
    expect(
      _alpha8(midGradient.colors.first),
      lessThan(_alpha8(nearGradient.colors.first)),
    );
    expect(
      _alpha8(farGradient.colors.first),
      lessThan(_alpha8(midGradient.colors.first)),
    );

    final animated = tester.widget<AnimatedContainer>(
      find.descendant(
        of: find.byType(MessagingUserBubbleGlass),
        matching: find.byType(AnimatedContainer),
      ),
    );
    final decoration = animated.decoration! as BoxDecoration;
    expect(_alpha8(decoration.color!), 0);
    expect(decoration.gradient, isNull);
    expect(decoration.boxShadow ?? const <BoxShadow>[], isEmpty);
    // At rest the bubble carries the neutral hairline and the light is off.
    expect(decoration.border, isNotNull);
    expect(
      decoration.border!.top.color,
      MessagingDesktopMetrics.bubbleRestingBorder(
        theme.extension<LicoThemeColors>()!.line,
        isDark: true,
      ),
    );
    expect(painter.opacity, 0);
    expect(tester.takeException(), isNull);

    // Hover fades the light in and the resting hairline out.
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(
          body: Center(
            child: MessagingUserBubbleGlass(
              borderRadius: BorderRadius.circular(12),
              padding: const EdgeInsets.all(12),
              hovered: true,
              child: const Text('hello'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final litPaint = tester.widget<CustomPaint>(
      find.descendant(
        of: find.byType(MessagingBubbleEdgeGlow),
        matching: find.byType(CustomPaint),
      ),
    );
    final litPainter = litPaint.painter! as MessagingBubbleEdgeGlowPainter;
    expect(litPainter.opacity, 1);
    final litAnimated = tester.widget<AnimatedContainer>(
      find.descendant(
        of: find.byType(MessagingUserBubbleGlass),
        matching: find.byType(AnimatedContainer),
      ),
    );
    final litDecoration = litAnimated.decoration! as BoxDecoration;
    expect(_alpha8(litDecoration.border!.top.color), 0);
    expect(tester.takeException(), isNull);
  });
}
