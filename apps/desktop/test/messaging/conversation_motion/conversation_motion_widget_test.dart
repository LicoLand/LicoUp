import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/frontend/shared/messaging/conversation_motion/conversation_particle_field.dart';
import 'package:licoup/src/frontend/shared/messaging/conversation_motion/conversation_particle_globe.dart';
import 'package:licoup/src/frontend/shared/messaging/conversation_motion/steel_ball_waiting_indicator.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

const _anchors = ConversationParticleAnchors(
  sphere: Rect.fromLTWH(80, 40, 200, 200),
  avatar: Rect.fromLTWH(12, 12, 32, 32),
  composer: RRect.fromLTRBXY(12, 260, 292, 324, 18, 18),
);

Widget _app(Widget child, {bool reduced = false, bool ticking = true}) =>
    MaterialApp(
      theme: buildLicoTheme(),
      themeAnimationDuration: Duration.zero,
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduced),
        child: TickerMode(
          enabled: ticking,
          child: SizedBox(width: 320, height: 360, child: child),
        ),
      ),
    );

void main() {
  testWidgets(
    'loading globe shares the field and pauses without resetting it',
    (tester) async {
      await tester.pumpWidget(
        _app(const Center(child: ConversationParticleGlobe(diameter: 180))),
      );
      await tester.pump(const Duration(milliseconds: 100));
      ConversationParticlePainter painter() => tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((widget) => widget.painter)
          .whereType<ConversationParticlePainter>()
          .single;
      final original = painter();
      final seconds = original.clock.value;
      expect(original.anchors.sphere.size, const Size(180, 180));
      await tester.pumpWidget(
        _app(
          const Center(
            child: ConversationParticleGlobe(diameter: 180, active: false),
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 2));
      expect(painter().geometry, same(original.geometry));
      expect(painter().clock.value, seconds);
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pumpWidget(
        _app(
          const Center(child: ConversationParticleGlobe(diameter: 180)),
          reduced: true,
        ),
      );
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'overlay never blocks input; first content does not interrupt assembly',
    (tester) async {
      var tapped = 0;
      var assembled = false;
      var completed = 0;
      late StateSetter rebuild;
      await tester.pumpWidget(
        _app(
          StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return Stack(
                children: [
                  Center(
                    child: TextButton(
                      onPressed: () => tapped++,
                      child: const Text('Send'),
                    ),
                  ),
                  if (assembled)
                    const Text('First response is already visible'),
                  Positioned.fill(
                    child: ConversationParticleField(
                      assembled: assembled,
                      anchors: _anchors,
                      particleCount: 360,
                      onAssembled: () => completed++,
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      );
      await tester.tap(find.text('Send'));
      expect(tapped, 1);
      rebuild(() => assembled = true);
      await tester.pump();
      expect(find.text('First response is already visible'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 500));
      expect(completed, 0);
      await tester.pump(const Duration(seconds: 3));
      expect(completed, 1);
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'reduced motion and inactive/offstage loops do not schedule frames',
    (tester) async {
      final field = ConversationParticleField(
        assembled: false,
        anchors: _anchors,
        particleCount: 360,
      );
      await tester.pumpWidget(_app(field));
      expect(tester.binding.transientCallbackCount, greaterThan(0));
      await tester.pumpWidget(_app(field, ticking: false));
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpWidget(_app(field, reduced: true));
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pumpWidget(
        _app(const SteelBallWaitingIndicator(active: true), reduced: true),
      );
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pumpWidget(
        _app(const SteelBallWaitingIndicator(active: true)),
      );
      expect(tester.binding.transientCallbackCount, greaterThan(0));
      await tester.pumpWidget(
        _app(const SteelBallWaitingIndicator(active: false)),
      );
      expect(tester.binding.transientCallbackCount, 0);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is CustomPaint &&
              widget.painter is SteelBallWaitingPainter,
        ),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('disposing during flight cancels only the decorative ticker', (
    tester,
  ) async {
    var completed = 0;
    await tester.pumpWidget(
      _app(
        ConversationParticleField(
          assembled: true,
          anchors: _anchors,
          particleCount: 360,
          onAssembled: () => completed++,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 3));
    expect(completed, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('frequent parent rebuilds cannot restart the continuous clock', (
    tester,
  ) async {
    var completed = 0;
    late StateSetter rebuild;
    await tester.pumpWidget(
      _app(
        StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return ConversationParticleField(
              assembled: true,
              anchors: _anchors,
              particleCount: 120,
              onAssembled: () => completed++,
            );
          },
        ),
      ),
    );
    for (var frame = 0; frame < 140; frame++) {
      rebuild(() {});
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(completed, 1);
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
