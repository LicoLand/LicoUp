import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/frontend/appearance/appearance_visuals.dart';
import 'package:licoup/src/frontend/features/agents/ui/conversation/canonical_group_conversation_pane/reveal.dart';
import 'package:licoup/src/frontend/shared/ui/lico_skeleton.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

void main() {
  Widget scene({
    required Widget child,
    bool reduced = false,
    bool ticking = true,
    double motionScale = 1,
  }) => MaterialApp(
    themeAnimationDuration: Duration.zero,
    theme: buildLicoTheme().copyWith(
      extensions: [AppearanceVisuals(motionScale: motionScale)],
    ),
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: reduced),
      child: TickerMode(
        enabled: ticking,
        child: Center(child: child),
      ),
    ),
  );

  testWidgets(
    'skeleton stops and resumes across reduced and offstage changes',
    (tester) async {
      const skeleton = LicoSkeleton(width: 160, height: 14);
      await tester.pumpWidget(scene(child: skeleton));
      await tester.pump(const Duration(milliseconds: 80));
      expect(tester.binding.transientCallbackCount, greaterThan(0));

      await tester.pumpWidget(scene(child: skeleton, reduced: true));
      await tester.pump();
      expect(tester.binding.transientCallbackCount, 0);
      expect(find.byType(LicoSkeleton), findsOneWidget);

      await tester.pumpWidget(scene(child: skeleton));
      await tester.pump(const Duration(milliseconds: 80));
      expect(tester.binding.transientCallbackCount, greaterThan(0));
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(scene(child: skeleton, ticking: false));
      await tester.pump();
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pumpWidget(scene(child: skeleton));
      await tester.pump(const Duration(milliseconds: 80));
      expect(tester.binding.transientCallbackCount, greaterThan(0));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('skeleton updates the running period from appearance values', (
    tester,
  ) async {
    const skeleton = LicoSkeleton(width: 160, height: 14);
    await tester.pumpWidget(scene(child: skeleton));
    await tester.pump(const Duration(milliseconds: 160));
    final animation =
        tester
                .widget<AnimatedBuilder>(
                  find.descendant(
                    of: find.byType(LicoSkeleton),
                    matching: find.byType(AnimatedBuilder),
                  ),
                )
                .animation
            as AnimationController;
    final initialDuration = animation.duration!;
    await tester.pumpWidget(scene(child: skeleton, motionScale: 0.75));
    expect(animation.duration, initialDuration * 0.75);
    expect(animation.isAnimating, isTrue);
  });

  testWidgets('roster settles active opening and closing when motion reduces', (
    tester,
  ) async {
    Widget roster(bool visible) => CanonicalGroupRosterReveal(
      visible: visible,
      child: const SizedBox(
        key: Key('roster-content'),
        width: 160,
        height: 120,
      ),
    );
    await tester.pumpWidget(scene(child: roster(false)));
    await tester.pumpWidget(scene(child: roster(true)));
    await tester.pump(const Duration(milliseconds: 60));
    final revealedRegion = find.descendant(
      of: find.byType(CanonicalGroupRosterReveal),
      matching: find.byType(ClipRect),
    );
    expect(tester.getSize(revealedRegion).height, lessThan(120));

    await tester.pumpWidget(scene(child: roster(true), reduced: true));
    expect(tester.getSize(revealedRegion).height, 120);
    expect(find.byKey(const Key('roster-content')), findsOneWidget);
    expect(tester.binding.transientCallbackCount, 0);

    await tester.pumpWidget(scene(child: roster(true)));
    await tester.pumpWidget(scene(child: roster(false)));
    await tester.pump(const Duration(milliseconds: 60));
    expect(find.byKey(const Key('roster-content')), findsOneWidget);
    await tester.pumpWidget(scene(child: roster(false), reduced: true));
    await tester.pump();
    expect(find.byKey(const Key('roster-content')), findsNothing);
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
  });
}
