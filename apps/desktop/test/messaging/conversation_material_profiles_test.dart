import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_agent_bubble.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_user_bubble_glass.dart';
import 'package:licoup/src/frontend/layout/layout_destination_presentation.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/presentation/dashboard_card_destination_presentations.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/presentation/desktop_desktop_destination_presentations.dart';
import 'package:licoup/src/frontend/shared/layout_palette_projection.dart';
import 'package:licoup/src/frontend/shared/ui/continuous_stroke.dart';
import 'package:licoup/src/frontend/shared/ui/lico_pane_card.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

void main() {
  testWidgets('Dashboard owns a solid sidebar and opaque message roles', (
    tester,
  ) async {
    Color? expectedAccent;
    for (final presentation in <LayoutAgentsPresentation>[
      dashboardCardAgentsPresentation,
      desktopDesktopAgentsPresentation,
    ]) {
      final dashboard = identical(
        presentation,
        dashboardCardAgentsPresentation,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: buildLicoTheme(platformBrightness: Brightness.dark),
          home: Scaffold(
            body: Builder(
              builder: (context) => LayoutPaletteScope(
                palette: layoutPaletteFromColors(context.licoColors),
                child: Builder(
                  builder: (context) {
                    expectedAccent = context.licoColors.accent;
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
          // The own-speaker bubble is the solid brand gradient in the
          // opaque (light/Dashboard) profile; on dark glass it is a flat
          // accent tint so the ambient shows through.
          final gradient = decoration.gradient;
          if (gradient != null) {
            expect(
              (gradient as LinearGradient).colors.every((c) => c.a == 1),
              isTrue,
              reason: 'the own-speaker brand gradient stays opaque',
            );
          } else {
            // Opaque profiles re-ground the accent tint on the surface;
            // the glass profile keeps it translucent.
            expect(decoration.color!.a, dashboard ? 1.0 : closeTo(0.18, 0.01));
          }
        } else {
          // The dark agent bubble is the shared black mask — slightly
          // translucent over the ambient in every material profile.
          expect(decoration.color!.a, closeTo(0.722, 0.01));
          final border =
              (decoration.shape as ContinuousRoundedBorder).side.color;
          expect(
            border,
            dashboard ? expectedAccent!.withAlpha(46) : const Color(0x12FFFFFF),
          );
        }
      }
      if (dashboard) {
        // The sidebar is the floating LicoPaneCard — the dark Card-style
        // black-mask glass with the GlassEdgeLight rim, never an opaque
        // panel or a backdrop filter.
        expect(find.byType(LicoPaneCard), findsOneWidget);
        expect(find.byType(BackdropFilter), findsNothing);
      }
      expect(tester.takeException(), isNull);
    }
  });
}
