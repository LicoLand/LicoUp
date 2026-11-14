import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/frontend/shared/mascot/mascot_expression_motion.dart';

Widget _app(Widget child, {bool reduced = false}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: reduced),
    child: Center(child: child),
  ),
);

void main() {
  // Regression: translateByDouble's fourth argument is the homogeneous w
  // component. Passing 0 zeroed matrix entry m[15], projecting every point of
  // the subtree to infinity so the painted content rasterized as fully
  // transparent — sticker messages and the whole picker grid went blank.
  for (final (id, kind) in [
    ('happy', MascotExpressionMotionKind.bounce),
    ('wink', MascotExpressionMotionKind.sway),
    ('neutral', MascotExpressionMotionKind.breathe),
  ]) {
    testWidgets('$kind transform keeps a unit homogeneous component', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          MascotExpressionMotion(
            expressionId: id,
            child: const SizedBox(width: 96, height: 96),
          ),
        ),
      );
      // Let the entrance finish and sample several idle-loop phases.
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 400));
        final transform = tester.widget<Transform>(
          find.descendant(
            of: find.byType(MascotExpressionMotion),
            matching: find.byType(Transform),
          ),
        );
        expect(transform.transform.storage[15], closeTo(1.0, 1e-9));
        expect(transform.transform.determinant(), isNonZero);
        expect(transform.transform.storage.every((v) => v.isFinite), isTrue);
      }
    });
  }

  testWidgets('entrance completes to full opacity', (tester) async {
    await tester.pumpWidget(
      _app(
        const MascotExpressionMotion(
          expressionId: 'wink',
          child: SizedBox(width: 96, height: 96),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    final opacity = tester.widget<Opacity>(
      find.descendant(
        of: find.byType(MascotExpressionMotion),
        matching: find.byType(Opacity),
      ),
    );
    expect(opacity.opacity, 1.0);
  });

  testWidgets('reduced motion returns the child unwrapped', (tester) async {
    await tester.pumpWidget(
      _app(
        const MascotExpressionMotion(
          expressionId: 'wink',
          child: SizedBox(width: 96, height: 96),
        ),
        reduced: true,
      ),
    );
    await tester.pump();
    expect(
      find.descendant(
        of: find.byType(MascotExpressionMotion),
        matching: find.byType(Transform),
      ),
      findsNothing,
    );
    expect(find.byType(SizedBox), findsOneWidget);
  });
}
