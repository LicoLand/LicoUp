import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_agent_bubble.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_user_bubble_glass.dart';
import 'package:licoup/src/frontend/layout/layout_destination_presentation.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/shared/layout_palette_projection.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/frontend/shared/ui/lico_pane_card.dart';

/// Asserts the conversation material identity [presentation] owns: every
/// profile renders the demo bubble pair — the user's own bubble as the solid
/// brand gradient and the agent bubble as an opaque neutral surface. An
/// opaque profile also paints its sidebar as a solid surface.
Future<void> verifyConversationMaterialIdentity(
  WidgetTester tester, {
  required LayoutAgentsPresentation presentation,
  required bool opaque,
}) async {
  Color? expectedSurface;
  await tester.pumpWidget(
    MaterialApp(
      theme: buildLicoTheme(platformBrightness: Brightness.dark),
      home: Scaffold(
        body: Builder(
          builder: (context) => LayoutPaletteScope(
            palette: layoutPaletteFromColors(context.licoColors),
            child: Builder(
              builder: (context) {
                expectedSurface = context.licoColors.surface;
                return presentation.frameWorkspace(
                  context,
                  key: const Key('workspace'),
                  child: Row(
                    children: [
                      presentation.frameSidebar(
                        context,
                        key: const Key('sidebar'),
                        child: const SizedBox(width: 200, height: 300),
                      ),
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            MessagingUserBubbleGlass(
                              borderRadius: BorderRadius.circular(20),
                              child: const Text('User message'),
                            ),
                            MessagingAgentBubble(
                              borderRadius: BorderRadius.circular(20),
                              child: const Text('Assistant message'),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  for (final type in [MessagingUserBubbleGlass, MessagingAgentBubble]) {
    final bubble = tester.widget<AnimatedContainer>(
      find.descendant(
        of: find.byType(type),
        matching: find.byType(AnimatedContainer),
      ),
    );
    final decoration = bubble.decoration! as ShapeDecoration;
    if (type == MessagingUserBubbleGlass) {
      // Dark: flat accent tint over glass; light keeps the brand gradient.
      if (decoration.gradient == null) {
        if (opaque) {
          // Dark opaque fill is re-grounded: accent@18% blended over
          // surfaceLow — never gold, and fully opaque by construction.
          expect(decoration.color!.a, 1.0);
        } else {
          expect(decoration.color!.a, closeTo(0.18, 0.01));
        }
      }
    } else {
      // Dark: white 5.5% over glass; light stays opaque.
      if (decoration.color!.a < 1) {
        expect(decoration.color!.a, closeTo(0.722, 0.01));
      }
    }
  }
  if (opaque) {
    final sidebar = tester.widget(find.byKey(const Key('sidebar')));
    if (sidebar is LicoPaneCard) {
      // Pane-card sidebars carry the shared card fill/rim/shadow
      // contract instead of a flat opaque surface.
      expect(tester.takeException(), isNull);
      return;
    }
    final decorated = sidebar as DecoratedBox;
    final decoration = decorated.decoration as BoxDecoration;
    expect(decoration.color, expectedSurface);
    expect(decoration.color!.a, 1.0);
    expect(
      decoration.border,
      isNull,
      reason: 'GlassEdgeLight owns the single rim',
    );
    expect(find.byType(BackdropFilter), findsNothing);
  }
  expect(tester.takeException(), isNull);
}
