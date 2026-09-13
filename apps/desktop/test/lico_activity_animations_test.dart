import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/frontend/shared/ui/lico_activity_animations.dart';

void main() {
  testWidgets('parsing activity stops ticking when idle or reduced', (
    tester,
  ) async {
    Widget scene({required bool enabled, bool reduced = false}) => MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduced),
        child: Center(
          child: LicoTopEdgePulse(
            enabled: enabled,
            borderRadius: BorderRadius.circular(12),
            color: const Color(0xFFCDD2D9),
            child: const SizedBox(width: 180, height: 48),
          ),
        ),
      ),
    );
    await tester.pumpWidget(scene(enabled: true));
    await tester.pump(const Duration(milliseconds: 80));
    expect(tester.binding.transientCallbackCount, greaterThan(0));
    await tester.pumpWidget(scene(enabled: false));
    await tester.pump();
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(scene(enabled: true, reduced: true));
    await tester.pump();
    expect(tester.binding.transientCallbackCount, 0);
    expect(find.byKey(const Key('lico-top-edge-pulse-paint')), findsOneWidget);
  });

  test('spinner arc stays circular under non-square paint constraints', () {
    final rect = licoSpinnerArcRect(const Size(12, 20), 2);

    expect(rect.width, rect.height);
    expect(rect.center, const Offset(6, 10));
  });
}
