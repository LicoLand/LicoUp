import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_agent_bubble.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_user_bubble_glass.dart';
import 'package:licoup/src/frontend/layout/layout_destination_presentation.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/shared/layout_palette_projection.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

/// Asserts the conversation material identity [presentation] owns: an opaque
/// profile paints the user's own bubble as the brand gradient, the agent
/// bubble as a solid tint, and the sidebar as a solid surface, while a glass
/// profile keeps every message role translucent.
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
    if (opaque) {
      if (type == MessagingUserBubbleGlass) {
        expect(
          decoration.gradient,
          isNotNull,
          reason: 'the Plain own bubble is the brand fill',
        );
      } else {
        expect(decoration.color!.a, 1);
      }
    } else {
      expect(decoration.color!.a, lessThan(1));
    }
  }
  if (opaque) {
    final sidebar = tester.widget<DecoratedBox>(
      find.byKey(const Key('sidebar')),
    );
    final decoration = sidebar.decoration as BoxDecoration;
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
