import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/frontend/layout/layout_palette.dart';

import '../support/test_layout_palette.dart';

void main() {
  final light = testLayoutPalette;

  test('palette is an immutable value independent of the app theme type', () {
    expect(light.isDark, isFalse);
    expect(light, equals(light));
    expect(light.hashCode, equals(light.hashCode));
  });

  testWidgets('scope exposes the active neutral palette', (tester) async {
    LayoutPalette? found;
    await tester.pumpWidget(
      LayoutPaletteScope(
        palette: light,
        child: Builder(
          builder: (context) {
            found = context.layoutPalette;
            return const SizedBox();
          },
        ),
      ),
    );
    expect(found, light);
  });

  testWidgets('scope notifies dependents only when palette values change', (
    tester,
  ) async {
    final builds = ValueNotifier<int>(0);
    addTearDown(builds.dispose);
    final consumer = _PaletteConsumer(builds);

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: LayoutPaletteScope(palette: light, child: consumer),
      ),
    );
    expect(builds.value, 1);

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: LayoutPaletteScope(palette: testLayoutPalette, child: consumer),
      ),
    );
    expect(builds.value, 1);

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: LayoutPaletteScope(
          palette: testLayoutPaletteAlternate,
          child: consumer,
        ),
      ),
    );
    expect(builds.value, 2);
  });

  testWidgets('scope fails closed when no palette is provided', (tester) async {
    Object? error;
    await tester.pumpWidget(
      Builder(
        builder: (context) {
          try {
            context.layoutPalette;
          } catch (value) {
            error = value;
          }
          return const SizedBox();
        },
      ),
    );
    expect(error, isA<StateError>());
  });
}

final class _PaletteConsumer extends StatelessWidget {
  const _PaletteConsumer(this.builds);

  final ValueNotifier<int> builds;

  @override
  Widget build(BuildContext context) {
    context.layoutPalette;
    builds.value += 1;
    return const SizedBox();
  }
}
