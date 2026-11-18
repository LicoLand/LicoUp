import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_sticker_panel.dart';

import 'support/messaging_sticker_test_support.dart';

void main() {
  testWidgets('dark sticker panel matches the demo card', (tester) async {
    await tester.pumpWidget(
      const MessagingStickerTestApp(
        child: Scaffold(
          body: Center(
            child: MessagingStickerPanel(
              key: Key('messaging-sticker-panel'),
              onSendSticker: messagingStickerNoop,
              onInsertEmoji: messagingStickerNoop,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      for (final element in find.byType(Image).evaluate()) {
        final image = element.widget as Image;
        await precacheImage(image.image, element);
      }
    });
    await tester.pumpAndSettle();
    await expectLater(
      find.byKey(const Key('messaging-sticker-panel')),
      matchesGoldenFile('../goldens/messaging_sticker_panel_dark.png'),
    );
  });
}
