import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/frontend/shared/messaging/conversation_motion/conversation_particle_geometry.dart';

const _anchors = ConversationParticleAnchors(
  sphere: Rect.fromLTWH(390, 140, 320, 320),
  avatar: Rect.fromLTWH(32, 72, 36, 36),
  composer: RRect.fromLTRBXY(32, 530, 672, 618, 24, 24),
);

void main() {
  test(
    'curl folds a fixed thin shell continuously instead of rotating a grid',
    () {
      final field = ConversationParticleGeometry(count: 720);
      List<double> shellDistances(double seconds) {
        field.writeFrame(seconds, _anchors);
        final points = <List<double>>[];
        for (var i = 0; i < field.count; i += 7) {
          final z = field.depth[i] * 2 - 1;
          final scale = (3.9 - z) / (3.9 * _anchors.sphere.shortestSide * 0.46);
          final x =
              (field.positions[i * 2] - _anchors.sphere.center.dx) * scale;
          final y =
              (field.positions[i * 2 + 1] - _anchors.sphere.center.dy) * scale;
          expect(x * x + y * y + z * z, closeTo(1, 0.00001));
          points.add([x, y, z]);
        }
        return [
          for (var i = 0; i < points.length - 1; i++)
            math.sqrt(
              List.generate(
                3,
                (axis) => math.pow(points[i][axis] - points[i + 1][axis], 2),
              ).reduce((a, b) => a + b),
            ),
        ];
      }

      final before = shellDistances(0);
      final after = shellDistances(3);
      final changed = [
        for (var i = 0; i < before.length; i++) (before[i] - after[i]).abs(),
      ];
      // Rigid rotation preserves all pairwise 3D distances. Local flow must
      // stretch a substantial fraction while keeping every point on the shell.
      expect(changed.where((value) => value > 0.04).length, greaterThan(40));
      field.writeFrame(3, _anchors);
      final repeat = Float32List.fromList(field.positions);
      final bytes = field.allocatedBytes;
      field.writeFrame(3600, _anchors);
      field.writeFrame(3, _anchors);
      expect(field.positions, orderedEquals(repeat));
      expect(field.allocatedBytes, bytes);
    },
  );

  test('the same particles leave the live shell with continuous velocity', () {
    final field = ConversationParticleGeometry(count: 720);
    const launch = 8.0;
    const step = 0.008;
    field.writeFrame(launch - step, _anchors);
    final before = Float32List.fromList(field.positions);
    field.writeFrame(launch, _anchors);
    final start = Float32List.fromList(field.positions);
    field.writeFrame(launch + step, _anchors);
    final uninterrupted = Float32List.fromList(field.positions);
    field.assemble(seconds: launch, duration: 2, anchors: _anchors);
    expect(field.positions, orderedEquals(start));
    field.writeFrame(launch + step, _anchors);
    for (var i = 0; i < field.positions.length; i++) {
      final incoming = (start[i] - before[i]) / step;
      final outgoing = (field.positions[i] - start[i]) / step;
      final naturalOutgoing = (uninterrupted[i] - start[i]) / step;
      // Strong curl has genuine local acceleration. Compare the interruption
      // to that same forward interval, rather than demanding constant speed.
      final acceleration = naturalOutgoing - incoming;
      expect((outgoing - incoming - acceleration).abs(), lessThan(1.5));
    }
  });

  test('dense curl folds depart inside the conversation surface', () {
    final field = ConversationParticleGeometry();
    field.assemble(seconds: 0, duration: 2, anchors: _anchors);
    // A first streamed sentence can move the measured avatar before the shell
    // has finished releasing; its layout update must not reapply a long impulse.
    final earlyReplyAnchors = ConversationParticleAnchors(
      sphere: _anchors.sphere,
      avatar: const Rect.fromLTWH(32, 64, 36, 36),
      composer: _anchors.composer,
    );
    field.assemble(seconds: 0.08, duration: 1.92, anchors: earlyReplyAnchors);
    const surface = Rect.fromLTWH(0, 0, 760, 700);
    for (var frame = 1; frame <= 24; frame++) {
      field.writeFrame(0.08 + frame / 30, earlyReplyAnchors);
      var escaped = 0;
      for (var i = 0; i < field.count; i++) {
        if (!surface.contains(
          Offset(field.positions[i * 2], field.positions[i * 2 + 1]),
        )) {
          escaped++;
        }
      }
      expect(escaped, 0, reason: 'Particles escaped the sheet at frame $frame');
    }
  });

  test(
    'wave join retains velocity and every identity reaches a real target',
    () {
      final field = ConversationParticleGeometry(count: 720);
      final glyph = ConversationParticleGlyph(
        Float32List.fromList([0.25, 0.25, 0.75, 0.75]),
      );
      field.assemble(seconds: 0, duration: 2, anchors: _anchors, glyph: glyph);
      const dt = 0.003;
      var maxVelocityChange = 0.0;
      // The per-particle wave joins fall in this narrow interval.
      for (var t = 0.978; t < 1.14; t += dt) {
        field.writeFrame(t - dt, _anchors);
        final before = Float32List.fromList(field.positions);
        field.writeFrame(t, _anchors);
        final now = Float32List.fromList(field.positions);
        field.writeFrame(t + dt, _anchors);
        for (var i = 0; i < now.length; i++) {
          final delta =
              (field.positions[i] - 2 * now[i] + before[i]).abs() / dt;
          maxVelocityChange = math.max(maxVelocityChange, delta);
        }
      }
      expect(maxVelocityChange, lessThan(12));
      field.writeFrame(2, _anchors);
      var avatarCount = 0;
      var composerCount = 0;
      for (var i = 0; i < field.count; i++) {
        final point = Offset(
          field.positions[i * 2],
          field.positions[i * 2 + 1],
        );
        if (_anchors.avatar!.contains(point)) {
          avatarCount++;
          expect(point, anyOf(const Offset(41, 81), const Offset(59, 99)));
        } else {
          composerCount++;
          expect(_anchors.composer!.inflate(0.01).contains(point), isTrue);
          expect(_anchors.composer!.deflate(0.01).contains(point), isFalse);
        }
        expect(field.opacity[i], 0);
      }
      expect(avatarCount, greaterThan(200));
      expect(composerCount, greaterThan(450));
    },
  );

  test(
    'mid-flight resize preserves position and velocity before retargeting',
    () {
      final field = ConversationParticleGeometry(count: 360);
      field.assemble(seconds: 1, duration: 2, anchors: _anchors);
      field.writeFrame(1.9, _anchors);
      final current = Float32List.fromList(field.positions);
      field.writeFrame(1.902, _anchors);
      final uninterrupted = Float32List.fromList(field.positions);
      const resized = ConversationParticleAnchors(
        sphere: Rect.fromLTWH(390, 140, 320, 320),
        avatar: Rect.fromLTWH(40, 84, 36, 36),
        composer: RRect.fromLTRBXY(40, 510, 740, 618, 24, 24),
      );
      field.assemble(seconds: 1.9, duration: 1.1, anchors: resized);
      expect(field.positions, orderedEquals(current));
      field.writeFrame(1.902, resized);
      for (var i = 0; i < current.length; i++) {
        // Compare the same forward step: a backward finite difference would
        // include the existing wave acceleration and mislabel it a velocity jump.
        expect(field.positions[i], closeTo(uninterrupted[i], 0.002));
      }
    },
  );

  test(
    'sampling uses only opaque local mark pixels and normalizes coordinates',
    () {
      final bytes = Uint8List(4 * 4 * 4);
      bytes[(1 * 4 + 2) * 4 + 3] = 255;
      final glyph = ConversationParticleGlyph.fromRgba(
        bytes,
        width: 4,
        height: 4,
      )!;
      expect(glyph.normalizedPositions, orderedEquals([0.625, 0.375]));
      bytes.fillRange(0, bytes.length, 0);
      expect(glyph.normalizedPositions, orderedEquals([0.625, 0.375]));
      expect(
        ConversationParticleGlyph.fromRgba(bytes, width: 4, height: 4),
        isNull,
      );
    },
  );

  test('late target measurements cannot resurrect deposited particles', () {
    final field = ConversationParticleGeometry(count: 120);
    field.assemble(seconds: 0, duration: 2, anchors: _anchors);
    field.writeFrame(1.94, _anchors);
    final opacity = Float32List.fromList(field.opacity);
    final depth = Float32List.fromList(field.depth);
    field.assemble(seconds: 1.94, duration: 0.24, anchors: _anchors);
    expect(field.opacity, orderedEquals(opacity));
    expect(field.depth, orderedEquals(depth));
    field.writeFrame(2.18, _anchors);
    expect(field.opacity, everyElement(0));
  });
}
