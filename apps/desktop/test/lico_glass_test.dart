import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_conversation_overlay_glass.dart';
import 'package:licoup/src/frontend/shared/ui/glass_lens.dart';
import 'package:licoup/src/frontend/shared/ui/lico_glass.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

void main() {
  test('specular rim painter is a conic highlight, not a uniform color', () {
    const painter = GlassSpecularRimPainter(
      borderRadius: BorderRadius.all(Radius.circular(16)),
      rimHi: Color(0xA8FFFFFF),
      rimLo: Color(0x24FFFFFF),
      lightAngle: LicoGlass.restLightAngle,
      enclose: true,
    );
    expect(painter.enclose, isTrue);
    expect(painter.rimHi, isNot(equals(painter.rimLo)));
    expect(painter.rimHi.a, greaterThan(painter.rimLo.a));
    expect(painter.lightAngle, LicoGlass.restLightAngle);

    final recorder = PictureRecorder();
    painter.paint(Canvas(recorder), const Size(32, 32));
    expect(recorder.endRecording(), isNotNull);
  });

  testWidgets(
    'overlay glass paints the specular rim outside the backdrop clip',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildLicoTheme(platformBrightness: Brightness.dark),
          home: const Scaffold(
            body: Center(
              child: SizedBox(
                width: 180,
                height: 80,
                child: MessagingConversationOverlayGlass(
                  borderRadius: BorderRadius.all(Radius.circular(12)),
                  child: SizedBox.expand(),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final rimPaint = find.byWidgetPredicate(
        (widget) =>
            widget is CustomPaint &&
            widget.foregroundPainter is GlassSpecularRimPainter,
      );
      expect(rimPaint, findsOneWidget);
      expect(
        find.descendant(of: rimPaint, matching: find.byType(ClipRRect)),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(ClipRRect),
          matching: find.byType(BackdropFilter),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'conversation overlay glass keeps intrinsic height so header chrome lays out',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildLicoTheme(platformBrightness: Brightness.dark),
          home: const Scaffold(
            body: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: MessagingConversationOverlayGlass(
                      borderRadius: BorderRadius.all(Radius.circular(999)),
                      child: SizedBox(height: 40, child: Text('identity')),
                    ),
                  ),
                  AspectRatio(
                    aspectRatio: 1,
                    child: MessagingConversationOverlayGlass(
                      borderRadius: BorderRadius.all(Radius.circular(999)),
                      child: Center(child: Text('btn')),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('identity'), findsOneWidget);
      expect(find.text('btn'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('glass lens fragment program loads from the registered asset', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final program = await FragmentProgram.fromAsset(GlassLens.asset);
      expect(program, isNotNull);
    });
  });

  testWidgets('disableAnimations does not track the pointer light', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLicoTheme(platformBrightness: Brightness.dark),
        home: Builder(
          builder: (context) {
            return MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: const Scaffold(
                body: Center(
                  child: SizedBox(
                    width: 80,
                    height: 80,
                    child: LicoGlass(
                      borderRadius: BorderRadius.all(Radius.circular(40)),
                      fill: Color(0x22FFFFFF),
                      trackLight: true,
                      gelPress: true,
                      child: SizedBox.expand(),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
    await tester.pump();

    expect(
      find.descendant(
        of: find.byType(LicoGlass),
        matching: find.byType(MouseRegion),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: find.byType(LicoGlass),
        matching: find.byType(Transform),
      ),
      findsNothing,
    );
  });
}
