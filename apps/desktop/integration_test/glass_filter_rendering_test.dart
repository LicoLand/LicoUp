import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:licoup/src/frontend/shared/ui/glass_lens.dart';

/// Synthetic renderer verification; no application state or Agent is opened.
/// Run on an Impeller device with the repository's Flutter toolchain runner.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Impeller backdrop lens binds its input texture and preserves the interior',
    (tester) async {
      expect(
        GlassLens.isSupported,
        isTrue,
        reason: 'This integration check requires an Impeller renderer.',
      );
      await GlassLens.ensureLoaded();
      final lens = GlassLens.createFilter(
        size: const Size(128, 128),
        radius: 16,
        displace: 4,
      );
      expect(lens, isNotNull);
      final key = GlobalKey();

      Future<ByteData> render(ui.ImageFilter? filter) async {
        const gradient = DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFF000000), Color(0xFFFF0000)],
            ),
          ),
          child: SizedBox.expand(),
        );
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Center(
              child: RepaintBoundary(
                key: key,
                child: SizedBox(
                  width: 128,
                  height: 128,
                  child: filter == null
                      ? gradient
                      : Stack(
                          fit: StackFit.expand,
                          children: [
                            gradient,
                            ClipRect(
                              child: BackdropFilter(
                                filter: filter,
                                child: const SizedBox.expand(),
                              ),
                            ),
                          ],
                        ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage();
        try {
          return (await image.toByteData())!;
        } finally {
          image.dispose();
        }
      }

      try {
        final original = await render(null);
        final refracted = await render(lens!.filter);
        int red(ByteData data, int x) => data.getUint8((64 * 128 + x) * 4);
        expect(red(refracted, 80), closeTo(red(original, 80), 1));
        expect(red(refracted, 120), greaterThan(red(original, 120) + 2));
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        lens?.dispose();
      }
    },
  );
}
