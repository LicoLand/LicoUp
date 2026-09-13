import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/frontend/shared/messaging/conversation_motion/steel_ball_waiting_indicator.dart';

void main() {
  const system = ElasticSteelBallSystem(radius: 4, width: 48);

  test(
    'momentum passes left → middle → right and returns after the end stop',
    () {
      final frames = [
        0.0,
        0.25,
        0.4,
        0.6,
        0.75,
        0.95,
      ].map(system.sample).toList();
      expect(
        frames.map((f) => [f.firstVelocity, f.secondVelocity, f.thirdVelocity]),
        [
          [48.0, 0.0, 0.0],
          [0.0, 48.0, 0.0],
          [0.0, 0.0, 48.0],
          [0.0, 0.0, -48.0],
          [0.0, -48.0, 0.0],
          [-48.0, 0.0, 0.0],
        ],
      );
    },
  );

  test(
    'arbitrary skipped frames conserve kinetic energy and cannot overlap',
    () {
      for (var i = 0; i < 1000; i++) {
        final frame = system.sample(i * 187.3817);
        expect(frame.first, greaterThanOrEqualTo(4));
        expect(frame.third, lessThanOrEqualTo(44));
        expect(frame.second - frame.first, greaterThanOrEqualTo(8 - 1e-12));
        expect(frame.third - frame.second, greaterThanOrEqualTo(8 - 1e-12));
        final energy =
            (frame.firstVelocity * frame.firstVelocity +
                frame.secondVelocity * frame.secondVelocity +
                frame.thirdVelocity * frame.thirdVelocity) /
            2;
        expect(energy, 1152);
      }
    },
  );

  test('contact is continuous; only a wall reverses total momentum', () {
    for (final phase in [0.175, 0.325, 0.675, 0.825]) {
      final before = system.sample(phase - 1e-8);
      final after = system.sample(phase + 1e-8);
      expect(after.first, closeTo(before.first, 1e-6));
      expect(after.second, closeTo(before.second, 1e-6));
      expect(after.third, closeTo(before.third, 1e-6));
      expect(
        after.firstVelocity + after.secondVelocity + after.thirdVelocity,
        before.firstVelocity + before.secondVelocity + before.thirdVelocity,
      );
    }
    final beforeWall = system.sample(0.5 - 1e-8);
    final afterWall = system.sample(0.5 + 1e-8);
    expect(beforeWall.thirdVelocity, -afterWall.thirdVelocity);
    expect(beforeWall.third, closeTo(44, 1e-6));
    expect(afterWall.third, closeTo(44, 1e-6));
    final start = system.sample(0);
    final repeat = system.sample(10000);
    expect(repeat.first, start.first);
    expect(repeat.firstVelocity, start.firstVelocity);
  });
}
