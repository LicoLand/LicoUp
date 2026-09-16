import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_conversation_overlay_glass.dart';
import 'package:licoup/src/frontend/shared/ui/glass_lens.dart';
import 'package:licoup/src/frontend/shared/ui/apple_glass.dart';
import 'package:licoup/src/frontend/features/agent_hub/ui/agent_hub_surface.dart';
import 'package:licoup/src/frontend/shared/ui/lico_glass.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

void main() {
  testWidgets('surface hairlines preserve the content constraints', (
    tester,
  ) async {
    const contentKey = Key('surface-content');
    for (final inset in [0.0, 8.0]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 180,
              height: 150,
              child: AgentHubSurface(
                padding: EdgeInsets.all(inset),
                child: const SizedBox.expand(key: contentKey),
              ),
            ),
          ),
        ),
      );
      expect(
        tester.getSize(find.byKey(contentKey)),
        Size(180 - 2 * inset, 150 - 2 * inset),
      );
    }
  });

  for (final apple in [false, true]) {
    testWidgets(
      'glass preserves editing state across chrome changes (apple=$apple)',
      (tester) async {
        final controller = TextEditingController();
        final focus = FocusNode();
        late StateSetter update;
        var phase = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                final field = Material(
                  child: TextField(controller: controller, focusNode: focus),
                );
                return MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    highContrast: phase == 3,
                    disableAnimations: phase == 4,
                  ),
                  child: Center(
                    child: SizedBox(
                      width: 240,
                      height: 80,
                      child: apple
                          ? AppleGlassSurface(
                              borderRadius: BorderRadius.circular(12),
                              focused: phase == 1,
                              idleBorderColor: phase == 2
                                  ? Colors.orange
                                  : null,
                              fillAlpha: phase == 5 ? 50 : null,
                              child: field,
                            )
                          : LicoGlass(
                              borderRadius: BorderRadius.circular(12),
                              fill: phase == 5
                                  ? const Color(0x330000FF)
                                  : Colors.blue,
                              focused: phase == 1,
                              focusColor: Colors.red,
                              readBackdrop: phase == 5,
                              trackLight: phase != 2,
                              gelPress: phase != 2,
                              pressed: phase == 1,
                              shadows: phase == 2
                                  ? const [BoxShadow(blurRadius: 2)]
                                  : null,
                              child: field,
                            ),
                    ),
                  ),
                );
              },
            ),
          ),
        );
        await tester.enterText(find.byType(TextField), 'synthetic draft');
        controller.selection = const TextSelection(
          baseOffset: 2,
          extentOffset: 7,
        );
        await tester.pump();
        final editable = tester.state(find.byType(EditableText));
        final value = controller.value;
        for (final next in [1, 2, 3, 4, 5, 0]) {
          update(() => phase = next);
          await tester.pump();
          expect(
            identical(tester.state(find.byType(EditableText)), editable),
            isTrue,
          );
          expect(focus.hasFocus, isTrue);
          expect(controller.value, value);
        }
        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
        focus.dispose();
      },
    );
  }

  testWidgets('focus warning and contrast rings remain above opaque fill', (
    tester,
  ) async {
    final cases = <(Widget, bool, Color)>[
      (
        const LicoGlass(
          borderRadius: BorderRadius.zero,
          fill: Colors.blue,
          focused: true,
          focusColor: Colors.red,
          child: SizedBox.expand(),
        ),
        false,
        Colors.red,
      ),
      (
        const AppleGlassSurface(
          borderRadius: BorderRadius.zero,
          idleBorderColor: Colors.green,
          child: SizedBox.expand(),
        ),
        false,
        Colors.green,
      ),
      (
        const LicoGlass(
          borderRadius: BorderRadius.zero,
          fill: Colors.blue,
          child: SizedBox.expand(),
        ),
        true,
        Colors.white,
      ),
    ];
    for (final (child, contrast, expected) in cases) {
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: buildLicoTheme(platformBrightness: Brightness.dark),
          home: MediaQuery(
            data: MediaQueryData(highContrast: contrast),
            child: Center(
              child: RepaintBoundary(
                key: key,
                child: SizedBox(width: 64, height: 32, child: child),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final data = (await image.toByteData())!;
        final pixel = 32 * 4;
        expect(data.getUint8(pixel), (expected.r * 255).round());
        expect(data.getUint8(pixel + 1), (expected.g * 255).round());
        expect(data.getUint8(pixel + 2), (expected.b * 255).round());
        expect(data.getUint8(pixel + 3), 255);
        image.dispose();
      });
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('lens refracts near the rim and leaves the interior unchanged', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final program = await FragmentProgram.fromAsset(GlassLens.asset);
      final sourceRecorder = PictureRecorder();
      Canvas(sourceRecorder).drawRect(
        const Rect.fromLTWH(0, 0, 128, 128),
        Paint()
          ..shader = const LinearGradient(
            colors: [Color(0xFF000000), Color(0xFFFF0000)],
          ).createShader(const Rect.fromLTWH(0, 0, 128, 128)),
      );
      final sourcePicture = sourceRecorder.endRecording();
      final source = await sourcePicture.toImage(128, 128);
      final shader = program.fragmentShader()
        ..setFloat(0, 128)
        ..setFloat(1, 128)
        ..setFloat(2, 16)
        ..setFloat(3, 4)
        ..setFloat(4, 0)
        ..setImageSampler(0, source);
      final recorder = PictureRecorder();
      Canvas(
        recorder,
      ).drawRect(const Rect.fromLTWH(0, 0, 128, 128), Paint()..shader = shader);
      final picture = recorder.endRecording();
      final output = await picture.toImage(128, 128);
      final original = (await source.toByteData())!;
      final refracted = (await output.toByteData())!;
      int red(ByteData data, int x) => data.getUint8((64 * 128 + x) * 4);
      expect(red(refracted, 80), closeTo(red(original, 80), 1));
      expect(red(refracted, 120), greaterThan(red(original, 120) + 2));
      output.dispose();
      picture.dispose();
      shader.dispose();
      source.dispose();
      sourcePicture.dispose();
    });
  });

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
    recorder.endRecording().dispose();
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
      findsOneWidget,
    );
    final mouse = tester.widget<MouseRegion>(
      find.descendant(
        of: find.byType(LicoGlass),
        matching: find.byType(MouseRegion),
      ),
    );
    expect(mouse.onHover, isNull);
    expect(mouse.onExit, isNull);
    final transform = tester.widget<Transform>(
      find.descendant(
        of: find.byType(LicoGlass),
        matching: find.byType(Transform),
      ),
    );
    expect(transform.transform.isIdentity(), isTrue);
  });
}
