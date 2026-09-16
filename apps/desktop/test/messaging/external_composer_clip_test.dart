import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/frontend/shared/messaging/external_conversation_composer.dart';

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

  testWidgets(
    'clip follows short and growing input without hiding runtime content',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 600);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var composerExtent = 72.0;
      late StateSetter resize;
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 800,
            height: 600,
            child: ExternalConversationComposerClip(
              child: StatefulBuilder(
                builder: (context, setState) {
                  resize = setState;
                  return Stack(
                    children: [
                      const Positioned(
                        left: 0,
                        top: 0,
                        child: SizedBox(
                          key: Key('pane-top-marker'),
                          width: 40,
                          height: 40,
                          child: ColoredBox(color: Colors.red),
                        ),
                      ),
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox(
                              key: const Key('runtime-controls'),
                              height: 40,
                              child: TextButton(
                                onPressed: () {},
                                child: const Text('Runtime controls'),
                              ),
                            ),
                            SizeChangedLayoutNotifier(
                              child: SizedBox(
                                key: const ValueKey<String>('composer-fixture'),
                                height: composerExtent,
                                child: const ColoredBox(color: Colors.blue),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      );
      for (final height in [72.0, 192.0, 72.0]) {
        resize(() => composerExtent = height);
        await tester.pumpAndSettle();
        final composer = tester.getRect(
          find.byKey(const ValueKey<String>('composer-fixture')),
        );
        final runtime = tester.getRect(
          find.byKey(const Key('runtime-controls')),
        );
        expect(composer.top, 600);
        expect(composer.height, height);
        expect(runtime.bottom, 600);
        expect(runtime.top, 560);
        expect(find.text('Runtime controls').hitTestable(), findsOneWidget);
        expect(
          tester.getTopLeft(find.byKey(const Key('pane-top-marker'))).dy,
          0,
        );
        expect(tester.takeException(), isNull);
      }
    },
  );

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
