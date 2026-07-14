import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_client/src/frontend/layout/profiles/workbench/mobile/workbench_mobile_bundle.dart';

void main() {
  final appearances = <String, ColorScheme>{
    'light': ColorScheme.fromSeed(
      seedColor: const Color(0xff365f8d),
      brightness: Brightness.light,
    ),
    'dark': ColorScheme.fromSeed(
      seedColor: const Color(0xff7251a8),
      brightness: Brightness.dark,
    ),
  };

  for (final appearance in appearances.entries) {
    testWidgets('preview is deterministic for ${appearance.key} appearance', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 420);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(useMaterial3: true, colorScheme: appearance.value),
          home: ColoredBox(
            color: appearance.value.surface,
            child: Center(
              child: RepaintBoundary(
                key: ValueKey<String>(
                  'workbench-mobile-${appearance.key}-golden',
                ),
                child: SizedBox(
                  width: 240,
                  child: Builder(builder: workbenchMobileBundle.previewBuilder),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await expectLater(
        find.byKey(
          ValueKey<String>('workbench-mobile-${appearance.key}-golden'),
        ),
        matchesGoldenFile(
          'goldens/workbench_mobile_preview_${appearance.key}.png',
        ),
      );
    });
  }
}
