import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_conversation_overlay_glass.dart';
import 'package:licoup/src/frontend/shared/ui/messaging_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

void main() {
  testWidgets('readability veil uses the shared black overlay token', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLicoTheme(platformBrightness: Brightness.dark),
        home: const Scaffold(
          body: Center(
            child: MessagingConversationOverlayGlass(
              borderRadius: BorderRadius.all(Radius.circular(12)),
              readabilityVeil: true,
              child: SizedBox(width: 180, height: 80),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final veil = tester.widget<DecoratedBox>(
      find.byKey(const Key('messaging-conversation-overlay-readability-veil')),
    );
    final decoration = veil.decoration as BoxDecoration;

    expect(
      decoration.color,
      MessagingDesktopMetrics.conversationOverlayReadabilityVeilFill(
        isDark: true,
      ),
    );
    expect(
      decoration.color,
      Colors.black.withAlpha(
        MessagingDesktopMetrics.conversationOverlayReadabilityVeilDarkAlpha,
      ),
    );
    expect(tester.takeException(), isNull);
  });
}
