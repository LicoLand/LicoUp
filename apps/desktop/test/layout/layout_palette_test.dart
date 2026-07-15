import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_client/src/frontend/layout/layout_palette.dart';

void main() {
  const light = LayoutPalette(
    background: Color(0xFFFFFFFF),
    surface: Color(0xFFFDFDFD),
    surfaceLow: Color(0xFFF5F5F5),
    surfaceHigh: Color(0xFFEAEAEA),
    surfaceHighest: Color(0xFFE0E0E0),
    line: Color(0xFFCCCCCC),
    text: Color(0xFF111111),
    textMuted: Color(0xFF666666),
    primary: Color(0xFF2255EE),
    primaryStrong: Color(0xFF1133AA),
    primaryFixed: Color(0xFFDDE5FF),
    textOnPrimary: Color(0xFFFFFFFF),
    info: Color(0xFF007799),
    infoMuted: Color(0xFFDDF7FF),
    success: Color(0xFF118844),
    warning: Color(0xFFAA6600),
    error: Color(0xFFBB2233),
  );

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
        child: LayoutPaletteScope(
          palette: _replaceBackground(light, light.background),
          child: consumer,
        ),
      ),
    );
    expect(builds.value, 1);

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: LayoutPaletteScope(
          palette: _replaceBackground(light, const Color(0xFF101820)),
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

LayoutPalette _replaceBackground(LayoutPalette palette, Color background) =>
    LayoutPalette(
      background: background,
      surface: palette.surface,
      surfaceLow: palette.surfaceLow,
      surfaceHigh: palette.surfaceHigh,
      surfaceHighest: palette.surfaceHighest,
      line: palette.line,
      text: palette.text,
      textMuted: palette.textMuted,
      primary: palette.primary,
      primaryStrong: palette.primaryStrong,
      primaryFixed: palette.primaryFixed,
      textOnPrimary: palette.textOnPrimary,
      info: palette.info,
      infoMuted: palette.infoMuted,
      success: palette.success,
      warning: palette.warning,
      error: palette.error,
    );

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
