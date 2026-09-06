import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/frontend/shared/messaging/external_conversation_composer.dart';
import 'package:licoup/src/frontend/shared/ui/messaging_desktop_tokens.dart';

void main() {
  testWidgets('external composer scope defaults to not hosted', (tester) async {
    late bool hosted;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            hosted = LayoutExternalComposerScope.isHosted(context);
            return const SizedBox();
          },
        ),
      ),
    );
    expect(hosted, isFalse);
  });

  testWidgets('clip hides the composer strip below the visible area', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 600);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const composerExtent =
        MessagingDesktopMetrics.conversationComposerOverlayExtent;
    await tester.pumpWidget(
      MaterialApp(
        home: Align(
          alignment: Alignment.topCenter,
          child: SizedBox(
            width: 800,
            height: 600,
            child: ExternalConversationComposerClip(
              child: Stack(
                children: [
                  Positioned(
                    left: 0,
                    top: 0,
                    child: Container(
                      key: const Key('pane-top-marker'),
                      width: 40,
                      height: 40,
                      color: Colors.red,
                    ),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: SizedBox(
                      key: const ValueKey<String>('composer-fixture'),
                      height: composerExtent,
                      child: const ColoredBox(color: Colors.blue),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    // Post-frame measurement applies the composer extent.
    await tester.pump();

    // The pane content renders taller than the viewport: the composer strip
    // starts exactly at the viewport's bottom edge and is clipped away.
    final composerTop = tester.getTopLeft(
      find.byKey(const ValueKey<String>('composer-fixture')),
    );
    expect(composerTop.dy, 600);

    // Content above the composer keeps its position (no shift).
    final marker = tester.getTopLeft(find.byKey(const Key('pane-top-marker')));
    expect(marker.dy, 0);
  });

  testWidgets('unbounded height leaves the child untouched', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: SingleChildScrollView(
          child: ExternalConversationComposerClip(
            child: SizedBox(
              key: ValueKey<String>('composer-fixture'),
              height: 120,
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(
      tester.getSize(find.byKey(const ValueKey<String>('composer-fixture'))),
      const Size(800, 120),
    );
  });
}
