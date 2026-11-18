import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/appearance/appearance_preset_config.dart';
import 'package:licoup/src/frontend/shared/ui/lico_ambient_clock.dart';
import 'package:licoup/src/frontend/shared/ui/lico_ambient_interaction.dart';
import 'package:licoup/src/frontend/shared/ui/lico_galaxy.dart';
import 'package:licoup/src/frontend/shared/ui/lico_window_ground.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

void main() {
  group('ambient-effect preset token', () {
    AppearancePresetConfig starlit() => builtInAppearancePresetConfigs
        .firstWhere((preset) => preset.id == AppearancePresetIds.starlitGold);

    test('explicit none token resolves to none', () {
      // A fixed preset that omits `ambient-effect` inherits the mode base
      // preset's token, so opting out is explicit.
      final custom = AppearancePresetConfig.fromJson({
        'schemaVersion': 2,
        'id': 'plain-mirror',
        'label': {'en': 'Plain mirror', 'zh-CN': '素镜'},
        'mode': 'dark',
        'tokens': {...starlit().tokens, 'ambient-effect': 'none'},
      });
      expect(
        licoColorsFor(
          custom.id,
          presets: [...builtInAppearancePresetConfigs, custom],
        ).ambientEffect,
        LicoAmbientEffect.none,
      );
    });

    test('starfield token resolves to starfield', () {
      expect(
        licoColorsFor(AppearancePresetIds.starlitGold).ambientEffect,
        LicoAmbientEffect.starfield,
      );
      final custom = AppearancePresetConfig.fromJson({
        'schemaVersion': 2,
        'id': 'starlit-mirror',
        'label': {'en': 'Starlit mirror', 'zh-CN': '星镜'},
        'mode': 'dark',
        'tokens': {...starlit().tokens},
      });
      expect(
        licoColorsFor(
          custom.id,
          presets: [...builtInAppearancePresetConfigs, custom],
        ).ambientEffect,
        LicoAmbientEffect.starfield,
      );
    });

    test('unknown token value fails preset validation', () {
      final result = validateAppearancePresetConfig({
        'schemaVersion': 2,
        'id': 'starlit-broken',
        'label': {'en': 'Broken', 'zh-CN': '损坏'},
        'mode': 'dark',
        'tokens': {...starlit().tokens, 'ambient-effect': 'meteor'},
      });
      expect(result.ok, isFalse);
      expect(result.errors.join('\n'), contains('tokens.ambient-effect'));
    });
  });

  group('LicoGalaxyUniforms', () {
    test('packs every shader input in declaration order', () {
      final values = LicoGalaxyUniforms.pack(
        size: const Size(1226, 872),
        dpr: 2,
        time: 42.5,
        glassRects: [
          RRect.fromRectAndRadius(
            const Rect.fromLTRB(10, 10, 800, 800),
            const Radius.circular(14),
          ),
          RRect.fromRectAndRadius(
            const Rect.fromLTRB(816, 10, 1216, 800),
            const Radius.circular(14),
          ),
        ],
        trail: [(x: 100.0, y: 200.0, amp: 0.5), (x: 90.0, y: 190.0, amp: 0.25)],
        parallax: const Offset(3, -2),
      );
      expect(values.length, LicoGalaxyUniforms.floatCount);
      expect(values.sublist(0, 5), [1226, 872, 2, 42.5, 2]);
      expect(values.sublist(5, 13), [10, 10, 800, 800, 816, 10, 1216, 800]);
      expect(values.sublist(13, 21), [0, 0, 0, 0, 0, 0, 0, 0]);
      expect(values.sublist(21, 25), [14, 14, 0, 0]);
      expect(values.sublist(25, 33), [100, 200, 0.5, 0, 90, 190, 0.25, 0]);
      expect(values.sublist(49, 53), [3, -2, 0, 0]);
    });
  });

  group('LicoGalaxyTrail', () {
    test('a still pointer raises the newest slot past 0.95 in 0.3 s', () {
      final trail = LicoGalaxyTrail();
      final t0 = Duration.zero;
      for (var ms = 0; ms <= 300; ms += 16) {
        trail.recordHover(
          const Offset(300, 300),
          t0 + Duration(milliseconds: ms),
        );
        trail.advance(0.016);
      }
      expect(trail.newestAmplitude, greaterThanOrEqualTo(0.95));
      expect(trail.points[1].amp, 0);
    });

    test('movement past 24 pt pushes a new slot and the old one eases out', () {
      final trail = LicoGalaxyTrail();
      final t0 = Duration.zero;
      for (var ms = 0; ms <= 200; ms += 16) {
        trail.recordHover(
          const Offset(300, 300),
          t0 + Duration(milliseconds: ms),
        );
        trail.advance(0.016);
      }
      trail.recordHover(
        const Offset(400, 300),
        const Duration(milliseconds: 216),
      );
      trail.advance(0.016);
      // The previous hotspot stays recorded as the second slot.
      expect(trail.points[0].x, 400);
      expect(trail.points[1].x, 300);
      // All slots settle under 2% within 1.5 s of the exit.
      trail.recordExit();
      for (var i = 0; i < (1500 / 16).round(); i++) {
        trail.advance(0.016);
      }
      for (final p in trail.points) {
        expect(p.amp.abs(), lessThan(0.02));
      }
    });

    test('amplitude never exceeds 1 and converges for any frame step', () {
      for (final dt in [0.5, 0.1, 1.0 / 30.0]) {
        final trail = LicoGalaxyTrail();
        trail.recordHover(const Offset(50, 50), Duration.zero);
        var steps = 0;
        while (steps < 40) {
          trail.recordHover(
            const Offset(50, 50),
            Duration(milliseconds: (dt * 1000 * steps).round()),
          );
          trail.advance(dt);
          expect(trail.newestAmplitude, inInclusiveRange(0, 1));
          steps++;
        }
        expect(trail.newestAmplitude, greaterThan(0.99));
      }
    });

    test('a random dt sequence keeps every slot amplitude within [0, 1]', () {
      final trail = LicoGalaxyTrail();
      final random = math.Random(7);
      var ms = 0;
      for (var i = 0; i < 200; i++) {
        ms += (random.nextDouble() * 500).round();
        trail.recordHover(
          Offset(50.0 + i * 3, 60.0 + i * 2),
          Duration(milliseconds: ms),
        );
        trail.advance(random.nextDouble() * 0.5);
        for (final p in trail.points) {
          expect(p.amp, inInclusiveRange(0, 1));
        }
      }
    });

    test('a single 1.5 s step settles the whole train after exit', () {
      final trail = LicoGalaxyTrail();
      trail.recordHover(const Offset(50, 50), Duration.zero);
      trail.advance(0.016);
      trail.recordExit();
      trail.advance(1.5);
      for (final p in trail.points) {
        expect(p.amp.abs(), lessThan(0.02));
      }
    });
  });

  group('licoDampedSpringStep', () {
    test('converges toward the target without overshoot at dt = 0.5', () {
      var error = -1.0;
      var velocity = 0.0;
      for (var i = 0; i < 60; i++) {
        final (e, v) = licoDampedSpringStep(
          error,
          velocity,
          omega: 6.0,
          dt: 0.5,
        );
        error = e;
        velocity = v;
        // Critically damped: the error stays on its own side of zero.
        expect(error, lessThanOrEqualTo(0));
      }
      expect(error.abs(), lessThan(0.01));
    });
  });
  group('LicoGalaxy', () {
    const paintKey = Key('lico-galaxy-paint');

    Widget scene({required String presetId, bool reduced = true}) =>
        MaterialApp(
          theme: buildLicoTheme(
            presetId: presetId,
            platformBrightness: Brightness.dark,
          ),
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: reduced),
            child: const SizedBox.expand(child: LicoGalaxy()),
          ),
        );

    Future<Uint8List> capture(WidgetTester tester) async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.descendant(
          of: find.byType(LicoGalaxy),
          matching: find.byType(RepaintBoundary),
        ),
      );
      final image = boundary.toImageSync();
      final data = await tester.runAsync(
        () => image.toByteData(format: ui.ImageByteFormat.png),
      );
      image.dispose();
      return data!.buffer.asUint8List();
    }

    testWidgets('none renders no galaxy paint', (tester) async {
      await tester.pumpWidget(scene(presetId: AppearancePresetIds.taroWaffle));
      expect(find.byType(LicoGalaxy), findsOneWidget);
      expect(find.byKey(paintKey), findsNothing);
    });

    testWidgets('the galaxy paints inside the shared wrappers', (tester) async {
      await tester.pumpWidget(scene(presetId: AppearancePresetIds.starlitGold));
      expect(find.byKey(paintKey), findsOneWidget);
      expect(
        find.ancestor(
          of: find.byKey(paintKey),
          matching: find.byType(IgnorePointer),
        ),
        findsWidgets,
      );
      expect(
        find.ancestor(
          of: find.byKey(paintKey),
          matching: find.byType(ExcludeSemantics),
        ),
        findsWidgets,
      );
      expect(
        find.ancestor(
          of: find.byKey(paintKey),
          matching: find.byType(RepaintBoundary),
        ),
        findsWidgets,
      );
      // The galaxy owns the ambient layer outright.
      expect(find.byType(LicoGalaxy), findsWidgets);
    });

    testWidgets('reduced motion stops the ticker and paints a static sky', (
      tester,
    ) async {
      await tester.pumpWidget(scene(presetId: AppearancePresetIds.starlitGold));
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pump();
      expect(tester.binding.hasScheduledFrame, isFalse);
      final first = await capture(tester);
      await tester.pump(const Duration(seconds: 2));
      final second = await capture(tester);
      expect(tester.binding.transientCallbackCount, 0);
      expect(listEquals(first, second), isTrue);
    });

    testWidgets('motion allowed ticks the sky within the repaint cadence '
        'cap', (tester) async {
      await tester.pumpWidget(
        scene(presetId: AppearancePresetIds.starlitGold, reduced: false),
      );
      expect(LicoAmbientClock.shared.isRunning, isTrue);

      var repaints = 0;
      final painter =
          tester.widget<CustomPaint>(find.byKey(paintKey)).painter!
              as LicoGalaxyPainter;
      void countRepaint() => repaints++;
      painter.clock.addListener(countRepaint);
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      painter.clock.removeListener(countRepaint);
      // One second of ticking may schedule at most 30 repaints.
      expect(repaints, lessThanOrEqualTo(LicoGalaxyPainter.maxFramesPerSecond));
      expect(repaints, greaterThan(0));
    });

    testWidgets('the same size reproduces the same sky', (tester) async {
      await tester.pumpWidget(scene(presetId: AppearancePresetIds.starlitGold));
      final first = await capture(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(scene(presetId: AppearancePresetIds.starlitGold));
      final second = await capture(tester);
      expect(listEquals(first, second), isTrue);
    });

    testWidgets('reduced motion ignores the pointer', (tester) async {
      final interaction = LicoAmbientInteraction();
      addTearDown(interaction.dispose);
      final site = _FakeGroundSite(interaction);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildLicoTheme(
            presetId: AppearancePresetIds.starlitGold,
            platformBrightness: Brightness.dark,
          ),
          home: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: SizedBox.expand(child: LicoGalaxy(site: site)),
          ),
        ),
      );
      final idle = await capture(tester);
      interaction.pointer.value = const Offset(320, 280);
      await tester.pump();
      expect(listEquals(idle, await capture(tester)), isTrue);
    });
  });

  group('window ground ambient ownership', () {
    const paintKey = Key('lico-galaxy-paint');

    Widget nested() => MaterialApp(
      theme: buildLicoTheme(
        presetId: AppearancePresetIds.starlitGold,
        platformBrightness: Brightness.dark,
      ),
      home: MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: LicoWindowGround(
          color: const Color(0xFF0B0B0E),
          child: LicoWindowGround(
            color: const Color(0x00000000),
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );

    testWidgets('a nested ground mounts no second ambient layer', (
      tester,
    ) async {
      await tester.pumpWidget(nested());
      expect(find.byType(LicoGalaxy), findsOneWidget);
      expect(find.byKey(paintKey), findsOneWidget);
    });
  });

  group('paintsGlassSmoke', () {
    testWidgets('tracks the shader program availability', (tester) async {
      // The shader loads in this environment, so the flag mirrors it;
      // with the program absent the same getter returns false.
      final expected =
          LicoGalaxyProgram.isLoaded &&
          licoColorsFor(AppearancePresetIds.starlitGold).ambientEffect ==
              LicoAmbientEffect.starfield;
      bool? flag;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildLicoTheme(
            presetId: AppearancePresetIds.starlitGold,
            platformBrightness: Brightness.dark,
          ),
          home: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: LicoWindowGround(
              color: const Color(0xFF0B0B0E),
              child: Builder(
                builder: (context) {
                  flag = LicoWindowGroundScope.paintsGlassSmokeOf(context);
                  return const SizedBox.expand();
                },
              ),
            ),
          ),
        ),
      );
      expect(flag, expected);
    });
  });
}

/// Minimal [LicoWindowGroundSite] for ungrounded galaxy tests: carries the
/// pointer input but no render box, so no glass regions resolve.
final class _FakeGroundSite implements LicoWindowGroundSite {
  _FakeGroundSite(this.interaction);

  @override
  final LicoAmbientInteraction interaction;

  @override
  final LicoGlassRegionRegistry glassRegions = LicoGlassRegionRegistry();

  @override
  RenderBox? get renderBox => null;

  @override
  bool get paintsGlassSmoke => false;

  @override
  bool get animatesAmbient => false;
}
