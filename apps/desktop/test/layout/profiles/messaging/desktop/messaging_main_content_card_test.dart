import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/destinations/messaging_desktop_destination_builders.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/presentation/messaging_desktop_destination_presentations.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/shell/messaging_main_content_card.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/tokens/messaging_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

import 'messaging_desktop_test_harness.dart';

void main() {
  test(
    'messagingMainContentCardDestinations covers all desktop destinations',
    () {
      expect(
        messagingMainContentCardDestinations,
        messagingDesktopDestinationBuilders.keys.toSet(),
      );
    },
  );

  testWidgets('MessagingMainContentCard uses shared mainContentCard tokens', (
    tester,
  ) async {
    configureMessagingTestView(tester, const Size(400, 300));
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLicoTheme(
          presetId: 'lico-soda',
          platformBrightness: Brightness.dark,
        ),
        home: Builder(
          builder: (context) => LayoutPaletteScope(
            palette: messagingDesktopTestPalette(context),
            child: const Scaffold(
              body: MessagingMainContentCard(
                child: SizedBox(key: Key('card-child')),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final card = tester.widget<Container>(
      find.byKey(const Key('messaging-desktop-main-card')),
    );
    final decoration = card.decoration! as BoxDecoration;
    expect(
      decoration.color,
      MessagingDesktopMetrics.mainContentCardFill(isDark: true),
    );
    expect(
      (decoration.borderRadius! as BorderRadius).topLeft.x,
      MessagingDesktopMetrics.mainCardCornerRadius,
    );
    expect(decoration.border!.top.width, MessagingDesktopMetrics.hairline);
    expect(
      decoration.boxShadow!.single.blurRadius,
      MessagingDesktopMetrics.mainContentCardShadowBlur,
    );
    expect(find.byKey(const Key('card-child')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('messaging desktop destinations keep a transparent canvas', (
    tester,
  ) async {
    configureMessagingTestView(tester, const Size(1280, 700));
    final harness = MessagingDesktopHarness();

    for (final destination in messagingDesktopDestinationBuilders.keys) {
      await tester.pumpWidget(
        MessagingDesktopTestShell(
          environment: messagingDesktopEnvironment(width: 1280, height: 700),
          activeDestination: destination,
          content: MessagingDesktopFixtureContent(harness),
          harness: harness,
        ),
      );
      await tester.pump();

      expect(
        find.byKey(const Key('messaging-destination-opaque-surface')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('messaging-desktop-main-card')),
        findsOneWidget,
      );
    }
  });
}
