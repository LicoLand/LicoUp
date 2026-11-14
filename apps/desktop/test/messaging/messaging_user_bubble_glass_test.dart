import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_bubble_edge_glow.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_user_bubble_glass.dart';
import 'package:licoup/src/frontend/shared/ui/continuous_stroke.dart';
import 'package:licoup/src/frontend/shared/ui/conversation_material_scope.dart';
import 'package:licoup/src/frontend/shared/ui/messaging_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

int _alpha8(Color color) => (color.toARGB32() >> 24) & 0xff;
int _red8(Color color) => (color.toARGB32() >> 16) & 0xff;
int _green8(Color color) => (color.toARGB32() >> 8) & 0xff;
int _blue8(Color color) => color.toARGB32() & 0xff;

void main() {
  group('MessagingDesktopMetrics bubble edge glow', () {
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
  });

  testWidgets('user bubble paints the accent tint with a rim light', (
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

    final glowPaint = tester.widget<CustomPaint>(
      find.descendant(
        of: find.byType(MessagingBubbleEdgeGlow),
        matching: find.byType(CustomPaint),
      ),
    );
    final painter =
        glowPaint.foregroundPainter! as MessagingBubbleEdgeGlowPainter;
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

    final animated = tester.widget<AnimatedContainer>(
      find.descendant(
        of: find.byType(MessagingUserBubbleGlass),
        matching: find.byType(AnimatedContainer),
      ),
    );
    final decoration = animated.decoration! as ShapeDecoration;
    final colors = theme.extension<LicoThemeColors>()!;
    // Dark surface: an opaque deep-violet diagonal (accent lifted on
    // `accentSurface`) with a violet under-glow and a violet rim
    // hairline; the brand gold gradient stays only on the light surface.
    final gradient = decoration.gradient as LinearGradient?;
    expect(gradient, isNotNull);
    expect(decoration.color, isNull);
    final expectedBody = MessagingUserBubbleGlass.deepVioletBody(colors.accent);
    expect(gradient!.colors, expectedBody);
    for (final stop in expectedBody) {
      expect(_alpha8(stop), 0xFF);
      // Deep violet is saturated — never the grey-mauve a pale alpha
      // blend produces.
      expect(HSLColor.fromColor(stop).saturation, greaterThan(0.45));
    }
    final rim = decoration.shadows!.single.color;
    expect(_alpha8(rim), 0x4D);
    // At rest the bubble carries the violet hairline and the light is off.
    final shape = decoration.shape as ContinuousRoundedBorder;
    expect(_alpha8(shape.side.color), 140);
    expect(
      HSLColor.fromColor(shape.side.color).hue,
      closeTo(HSLColor.fromColor(colors.accent).hue, 8),
    );
    expect(painter.opacity, 0);
    expect(tester.takeException(), isNull);

    // Spec §9: dark never shows gold — glass and opaque profiles alike.
    for (final opaque in [false, true]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            body: ConversationMaterialScope(
              opaqueBubbles: opaque,
              child: MessagingUserBubbleGlass(
                borderRadius: BorderRadius.circular(20),
                child: const Text('hi'),
              ),
            ),
          ),
        ),
      );
      final box = tester.widget<AnimatedContainer>(
        find.descendant(
          of: find.byType(MessagingUserBubbleGlass),
          matching: find.byType(AnimatedContainer),
        ),
      );
      final deco = box.decoration! as ShapeDecoration;
      final scopedGradient = deco.gradient as LinearGradient?;
      expect(
        scopedGradient,
        isNotNull,
        reason:
            'dark user bubble keeps the deep-violet body '
            '(opaque=$opaque)',
      );
      expect(
        scopedGradient!.colors.every((color) => _alpha8(color) == 0xFF),
        isTrue,
      );
    }

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
    final litPainter =
        litPaint.foregroundPainter! as MessagingBubbleEdgeGlowPainter;
    expect(litPainter.opacity, 1);
    final litAnimated = tester.widget<AnimatedContainer>(
      find.descendant(
        of: find.byType(MessagingUserBubbleGlass),
        matching: find.byType(AnimatedContainer),
      ),
    );
    final litDecoration = litAnimated.decoration! as ShapeDecoration;
    final litShape = litDecoration.shape as ContinuousRoundedBorder;
    expect(_alpha8(litShape.side.color), 0);
    expect(tester.takeException(), isNull);
  });
}
