import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/frontend/shared/messaging/conversation_motion/orb_waiting_indicator.dart';

void main() {
  const system = OrbSystem();
  const center = Offset(40, 14);
  const radius = 12.0;

  test('the loop is seamless and deterministic', () {
    final start = system.blobs(0, center, radius);
    final seam = system.blobs(1, center, radius);
    for (var i = 0; i < 3; i++) {
      expect(seam[i].$1.dx, closeTo(start[i].$1.dx, 1e-9));
      expect(seam[i].$1.dy, closeTo(start[i].$1.dy, 1e-9));
      expect(seam[i].$2, closeTo(start[i].$2, 1e-9));
    }
    expect(system.breath(0), closeTo(system.breath(1), 1e-9));
    for (var i = 0; i < 200; i++) {
      final a = system.blobs(i * 0.013, center, radius);
      final b = system.blobs(i * 0.013, center, radius);
      for (var j = 0; j < 3; j++) {
        expect(a[j], b[j]);
      }
    }
  });

  test('currents stay inside the sphere and keep a healthy size', () {
    for (var i = 0; i < 1000; i++) {
      final phase = i * 1.6180339887;
      for (final (blobCenter, blobRadius) in system.blobs(
        phase,
        center,
        radius,
      )) {
        // Currents may kiss the rim; the painter clips the sphere to contain
        // them, and the soft gradient edge makes the cut invisible.
        expect(
          (blobCenter - center).distance + blobRadius,
          lessThanOrEqualTo(radius * 1.05),
        );
        expect(blobRadius, greaterThan(radius * 0.35));
      }
      expect(system.breath(phase), inInclusiveRange(0, 1));
    }
  });

  test('the three currents follow distinct orbits', () {
    // Each current returns to its start exactly at the seam (integral
    // revolutions per loop), and their swept orbit areas differ, so the
    // interference pattern never repeats within one loop.
    final trajectories = [
      for (var blob = 0; blob < 3; blob++)
        [
          for (var step = 0; step <= 24; step++)
            system.blobs(step / 24, center, radius)[blob].$1,
        ],
    ];
    final swept = <double>[];
    for (final trajectory in trajectories) {
      expect(trajectory.last.dx, closeTo(trajectory.first.dx, 1e-9));
      expect(trajectory.last.dy, closeTo(trajectory.first.dy, 1e-9));
      var area = 0.0;
      for (var i = 1; i < trajectory.length; i++) {
        final a = trajectory[i - 1] - center;
        final b = trajectory[i] - center;
        area += a.dx * b.dy - a.dy * b.dx;
      }
      swept.add(area.abs() / 2);
    }
    expect(swept[0] - swept[1], isNot(closeTo(0, 1e-3)));
    expect(swept[0] - swept[2], isNot(closeTo(0, 1e-3)));
    expect(swept[1] - swept[2], isNot(closeTo(0, 1e-3)));
  });

  test(
    'painter repaints on phase, palette, halo and motion-policy changes',
    () {
      const sharedPhase = AlwaysStoppedAnimation<double>(0.35);
      OrbWaitingPainter at(
        double phase, {
        Animation<double>? shared,
        List<Color> palette = const [
          Color(0xff4f8a8b),
          Color(0xff6f6fd0),
          Color(0xff3f6fae),
        ],
        Color halo = const Color(0xff4f8a8b),
        bool reducedMotion = false,
      }) {
        return OrbWaitingPainter(
          phase: shared ?? AlwaysStoppedAnimation<double>(phase),
          palette: palette,
          halo: halo,
          reducedMotion: reducedMotion,
        );
      }

      final base = at(0.35, shared: sharedPhase);
      expect(base.shouldRepaint(at(0.36)), isTrue);
      expect(
        base.shouldRepaint(
          at(
            0.35,
            shared: sharedPhase,
            palette: const [
              Color(0xff4f8a8b),
              Color(0xff6f6fd0),
              Color(0xff3f6faf),
            ],
          ),
        ),
        isTrue,
      );
      expect(
        base.shouldRepaint(
          at(0.35, shared: sharedPhase, halo: const Color(0xff000000)),
        ),
        isTrue,
      );
      expect(
        base.shouldRepaint(at(0.35, shared: sharedPhase, reducedMotion: true)),
        isTrue,
      );
      expect(base.shouldRepaint(at(0.35, shared: sharedPhase)), isFalse);
    },
  );
}
