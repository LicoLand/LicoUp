import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/frontend/layout/profiles/native/mobile/native_mobile_bundle.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

import 'native_mobile_palette_fixture.dart';

void main() {
  for (final brightness in Brightness.values) {
    testWidgets(
      'Native mobile preview is deterministic for ${brightness.name}',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(480, 320);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        final theme = buildLicoTheme(platformBrightness: brightness);

        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: Builder(
              builder: (context) => withNativeMobileTestPalette(
                context,
                ColoredBox(
                  color:
                      ThemeData.estimateBrightnessForColor(
                            theme.scaffoldBackgroundColor,
                          ) ==
                          Brightness.dark
                      ? const Color(0xFF090B10)
                      : const Color(0xFFF4F5F7),
                  child: Center(
                    child: RepaintBoundary(
                      key: const Key('native-mobile-preview-frame'),
                      child: SizedBox(
                        width: 336,
                        child: Builder(
                          builder: nativeMobileBundle.previewBuilder,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        await expectLater(
          find.byKey(const Key('native-mobile-preview-frame')),
          matchesGoldenFile(
            'goldens/native_mobile_preview_${brightness.name}.png',
          ),
        );
      },
    );
  }
}
