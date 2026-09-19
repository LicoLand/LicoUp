import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/frontend/shared/ui/continuous_stroke.dart';

void main() {
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
