import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/frontend/shared/messaging/conversation_motion/conversation_particle_field.dart';
import 'package:licoup/src/frontend/shared/ui/lico_loading_indicator.dart';
import 'package:licoup/src/frontend/shared/messaging/conversation_motion/steel_ball_waiting_indicator.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

const _anchors = ConversationMotionAnchors(
  content: Rect.fromLTWH(80, 40, 200, 200),
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
    'loading feedback paints no particles and respects reduced motion',
    (tester) async {
      await tester.pumpWidget(
        _app(const Center(child: LicoLoadingIndicator())),
      );
      expect(find.byType(ConversationParticleField), findsNothing);
      expect(tester.binding.transientCallbackCount, greaterThan(0));
      await tester.pumpWidget(
        _app(const Center(child: LicoLoadingIndicator()), reduced: true),
      );
      await tester.pump(const Duration(seconds: 1));
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
