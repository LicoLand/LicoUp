import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/frontend/shared/ui/continuous_stroke.dart';

void main() {
  test('input border interpolates without leaving the continuous owner', () {
    const start = ContinuousOutlineInputBorder(
      borderSide: BorderSide(color: Colors.red, width: 1),
      gapPadding: 4,
    );
    const end = ContinuousOutlineInputBorder(
      borderSide: BorderSide(color: Colors.blue, width: 2),
      gapPadding: 8,
    );
    final middle = ShapeBorder.lerp(start, end, 0.5);
    expect(middle, isA<ContinuousOutlineInputBorder>());
    final continuous = middle! as ContinuousOutlineInputBorder;
    expect(continuous.borderSide.width, 1.5);
    expect(continuous.gapPadding, 6);
    expect(start.lerpTo(end, 1), end);
    expect(end.lerpFrom(start, 0), start);
  });

  test('floating label gap removes only the ring in both directions', () async {
    for (final direction in TextDirection.values) {
      for (final progress in [0.0, 0.5, 1.0]) {
        final recorder = ui.PictureRecorder();
        const border = ContinuousOutlineInputBorder(
          borderRadius: BorderRadius.zero,
          borderSide: BorderSide(color: Colors.white, width: 2),
        );
        border.paint(
          Canvas(recorder),
          const Rect.fromLTWH(10, 10, 100, 30),
          gapStart: direction == TextDirection.ltr ? 30 : 70,
          gapExtent: 20,
          gapPercentage: progress,
          textDirection: direction,
        );
        final picture = recorder.endRecording();
        final image = await picture.toImage(120, 50);
        final pixels = (await image.toByteData())!;
        int alpha(int x, int y) => pixels.getUint8((y * 120 + x) * 4 + 3);
        // Neither the interior nor the exterior may acquire a filled gap box.
        for (var x = 12; x < 108; x++) {
          expect(alpha(x, 9), 0, reason: '$direction $progress exterior $x');
          expect(alpha(x, 12), 0, reason: '$direction $progress interior $x');
        }
        final inGap = direction == TextDirection.ltr ? 40 : 80;
        expect(alpha(inGap, 10), progress == 0 ? 255 : 0);
        expect(alpha(15, 10), 255);
        expect(alpha(105, 10), 255);
        image.dispose();
        picture.dispose();
      }
    }
  });

  test('stadium stroke normalizes oversized radii before insetting', () {
    final rect = continuousStrokeRRect(
      const Size(720, 42),
      BorderRadius.circular(999),
      1,
    );
    expect(rect.left, 0.5);
    expect(rect.top, 0.5);
    expect(rect.tlRadiusX, 20.5);
    expect(rect.tlRadiusY, 20.5);
    expect(rect.brRadiusX, rect.tlRadiusX);
  });

  test('filled ring sits on the outer bound and deflates by stroke inset', () {
    const size = Size(32, 32);
    final outer = continuousStrokeOuterRRect(
      Offset.zero & size,
      BorderRadius.circular(16),
    );
    expect(outer.left, 0);
    expect(outer.top, 0);
    expect(outer.right, 32);
    expect(outer.bottom, 32);
    expect(outer.tlRadiusX, 16);
    expect(outer.tlRadiusY, 16);
    final inner = outer.deflate(1);
    expect(inner.left, 1);
    expect(inner.tlRadiusX, 15);
  });

  testWidgets(
    'ContinuousRoundedBorder paints a closed hairline without BoxBorder',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: DecoratedBox(
            decoration: ShapeDecoration(
              color: Color(0xFF101010),
              shape: ContinuousRoundedBorder(
                borderRadius: BorderRadius.all(Radius.circular(16)),
                side: BorderSide(color: Color(0xFFFFFFFF), width: 1),
              ),
            ),
            child: SizedBox(width: 32, height: 32),
          ),
        ),
      );
      final decorated = tester.widget<DecoratedBox>(find.byType(DecoratedBox));
      final decoration = decorated.decoration as ShapeDecoration;
      expect(decoration.shape, isA<ContinuousRoundedBorder>());
      expect((decoration.shape as ContinuousRoundedBorder).side.width, 1);
      expect(find.byType(DecoratedBox), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
