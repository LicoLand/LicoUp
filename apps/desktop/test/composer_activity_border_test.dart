import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/appearance/appearance_preset_config.dart';
import 'package:licoup/src/frontend/appearance/appearance_visuals.dart';
import 'package:licoup/src/frontend/shared/ui/composer_activity_border.dart';
import 'package:licoup/src/frontend/shared/ui/continuous_stroke.dart';

void main() {
  test('appearance accepts both working effects and defaults to breathing', () {
    expect(
      AppearanceVisuals.fromTokens(const {}).composerActivityEffect,
      ComposerActivityEffect.breathing,
    );
    final config = builtInAppearancePresetConfigs[1];
    for (final effect in ['breathing', 'pulse']) {
      final validated = validateAppearancePresetConfig({
        'schemaVersion': config.schemaVersion,
        'id': config.id,
        'label': config.label,
        'mode': config.mode.id,
        'tokens': {...config.tokens, 'composer-activity-effect': effect},
      });
      expect(validated.ok, isTrue);
      expect(
        AppearanceVisuals.fromTokens(
          validated.config!.tokens,
        ).composerActivityEffect.name,
        effect,
      );
    }
  });

  testWidgets(
    'live effects preserve child state and stop when idle or hidden',
    (tester) async {
      const childKey = Key('activity-draft');
      Widget scene({
        bool active = true,
        bool reduced = false,
        bool visible = true,
        String effect = 'breathing',
      }) => MaterialApp(
        theme: ThemeData(
          extensions: [
            AppearanceVisuals.fromTokens({'composer-activity-effect': effect}),
          ],
        ),
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: reduced),
          child: TickerMode(
            enabled: visible,
            child: Center(
              child: ComposerActivityBorder(
                active: active,
                borderRadius: BorderRadius.circular(999),
                color: Colors.white,
                child: const Material(
                  child: SizedBox(width: 240, child: TextField(key: childKey)),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpWidget(scene());
      await tester.enterText(find.byKey(childKey), 'Draft stays here');
      final original = tester.state(find.byKey(childKey));
      await tester.pump(const Duration(milliseconds: 80));
      expect(tester.binding.transientCallbackCount, greaterThan(0));
      await tester.pumpWidget(scene(effect: 'pulse'));
      await tester.pump(const Duration(milliseconds: 300));
      final paint = tester.widget<CustomPaint>(
        find.byKey(const Key('composer-activity-border-paint')),
      );
      expect(
        (paint.painter! as ComposerActivityBorderPainter).effect,
        ComposerActivityEffect.pulse,
      );
      expect(tester.state(find.byKey(childKey)), same(original));
      expect(find.text('Draft stays here'), findsOneWidget);
      // Remove focus so the field caret cannot account for a frame callback.
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpWidget(scene(active: false));
      await tester.pumpAndSettle();
      expect(tester.binding.transientCallbackCount, 0);
      expect(
        find.byKey(const Key('composer-activity-border-paint')),
        findsNothing,
      );
      await tester.pumpWidget(scene(reduced: true));
      await tester.pumpAndSettle();
      expect(tester.binding.transientCallbackCount, 0);
      expect(
        find.byKey(const Key('composer-activity-border-paint')),
        findsOneWidget,
      );
      await tester.pumpWidget(scene(visible: false));
      await tester.pumpAndSettle();
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pumpWidget(const SizedBox());
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.takeException(), isNull);
    },
  );

  test('stadium stroke normalizes oversized radii before insetting', () {
    final rect = continuousStrokeRRect(
      const Size(720, 42),
      BorderRadius.circular(999),
      1,
    );
    expect(rect.left, 0.5);
    expect(rect.top, 0.5);
    expect(rect.tlRadiusX, 20.5);
    expect(rect.tlRadiusY, 20.5);
    expect(rect.brRadiusX, rect.tlRadiusX);
  });
}
