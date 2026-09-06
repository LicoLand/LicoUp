import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/destinations/dashboard_desktop_destination_builders.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/presentation/dashboard_desktop_destination_presentations.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/shell/dashboard_main_content_card.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/tokens/dashboard_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

import 'dashboard_desktop_test_harness.dart';

void main() {
  test(
    'dashboardMainContentCardDestinations covers all desktop destinations',
    () {
      expect(
        dashboardMainContentCardDestinations,
        dashboardDesktopDestinationBuilders.keys.toSet(),
      );
    },
  );

  testWidgets('DashboardMainContentCard is a chromeless glass-flush region', (
    tester,
  ) async {
    configureDashboardTestView(tester, const Size(400, 300));
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLicoTheme(
          presetId: 'lico-soda',
          platformBrightness: Brightness.dark,
        ),
        home: Builder(
          builder: (context) => LayoutPaletteScope(
            palette: dashboardDesktopTestPalette(context),
            child: const Scaffold(
              body: DashboardMainContentCard(
                child: SizedBox(key: Key('card-child')),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // The region paints no fill, border, shadow, or edge light: content sits
    // flush on the native window glass and only the rounded clip shapes it.
    final card = tester.widget<ClipRRect>(
      find.byKey(const Key('dashboard-desktop-main-card')),
    );
    expect(
      card.borderRadius,
      BorderRadius.circular(MessagingDesktopMetrics.mainCardCornerRadius),
    );
    expect(card.clipBehavior, Clip.antiAlias);
    expect(
      find.descendant(
        of: find.byKey(const Key('dashboard-desktop-main-card')),
        matching: find.byType(DecoratedBox),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('dashboard-desktop-main-card')),
        matching: find.byType(CustomPaint),
      ),
      findsNothing,
    );
    expect(find.byKey(const Key('card-child')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('dashboard desktop destinations keep a transparent canvas', (
    tester,
  ) async {
    configureDashboardTestView(tester, const Size(1280, 700));
    final harness = DashboardDesktopHarness();

    for (final destination in dashboardDesktopDestinationBuilders.keys) {
      await tester.pumpWidget(
        DashboardDesktopTestShell(
          environment: dashboardDesktopEnvironment(width: 1280, height: 700),
          activeDestination: destination,
          content: DashboardDesktopFixtureContent(harness),
          harness: harness,
        ),
      );
      await tester.pump();

      expect(
        find.byKey(const Key('messaging-destination-opaque-surface')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('dashboard-desktop-main-card')),
        findsOneWidget,
      );
    }
  });
}
