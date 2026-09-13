import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_agent_bubble.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_user_bubble_glass.dart';
import 'package:licoup/src/frontend/layout/layout_destination_presentation.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/presentation/dashboard_desktop_destination_presentations.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/presentation/desktop_desktop_destination_presentations.dart';
import 'package:licoup/src/frontend/shared/layout_palette_projection.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

void main() {
  testWidgets('Dashboard owns translucent sidebar and opaque message roles', (
    tester,
  ) async {
    for (final presentation in <LayoutAgentsPresentation>[
      dashboardDesktopAgentsPresentation,
      desktopDesktopAgentsPresentation,
    ]) {
      final dashboard = identical(
        presentation,
        dashboardDesktopAgentsPresentation,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: buildLicoTheme(platformBrightness: Brightness.dark),
          home: Scaffold(
            body: Builder(
              builder: (context) => LayoutPaletteScope(
                palette: layoutPaletteFromColors(context.licoColors),
                child: Builder(
                  builder: (context) => presentation.frameWorkspace(
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
                  ),
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
        final fill = (bubble.decoration! as BoxDecoration).color!;
        expect(fill.a, dashboard ? 1 : lessThan(1));
      }
      if (dashboard) {
        final sidebar = tester.widget<DecoratedBox>(
          find.byKey(const Key('sidebar')),
        );
        final decoration = sidebar.decoration as BoxDecoration;
        expect(decoration.color!.a, closeTo(0.10, 0.001));
        expect(
          decoration.border,
          isNull,
          reason: 'GlassEdgeLight owns the single rim',
        );
        expect(find.byType(BackdropFilter), findsNothing);
      }
      expect(tester.takeException(), isNull);
    }
  });
}
