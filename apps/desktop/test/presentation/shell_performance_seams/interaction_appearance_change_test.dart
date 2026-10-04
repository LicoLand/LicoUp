import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/appearance/appearance_preset_config.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/appearance/appearance_projection_adapter.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/frontend/shell/client_shell.dart';
import 'package:licoup/src/presentation/shell/shell_effect.dart';

import 'support/interaction_measurement.dart';

/// The appearance-change interaction is measured and checked against the
/// registered workload definition.
///
/// The measurement counts the work the real shell performed for the action the
/// user performed, and it also asserts the result: the rendered shell has to
/// carry the theme the selected preset declares. A switch that rebuilds nothing
/// and changes nothing is not a passing measurement, and a counted rebuild
/// total on its own cannot tell those two apart.
void main() {
  testWidgets(
    'appearance-change stays inside the registered budget',
    (tester) async {
      late final Color backgroundBefore;
      late final Color primaryBefore;
      await measureInteraction(
        tester,
        'appearance-change',
        arrange: (fixture) async {
          final rendered = _renderedTheme(tester);
          backgroundBefore = rendered.scaffoldBackgroundColor;
          primaryBefore = rendered.colorScheme.primary;
        },
        act: (fixture) async =>
            fixture.changeAppearance(AppearancePresetIds.licoSodaLight),
        verify: (tester, fixture) async {
          // A theme change is a presentation change: the interaction itself must
          // leave the business state and the effect plane intact.
          expect(
            fixture.controller.appearancePreferenceOwner.presetId,
            AppearancePresetIds.licoSodaLight,
            reason:
                'the appearance interaction really changed the appearance state',
          );

          // The change has to reach the rendered shell, and what it renders has
          // to be the theme the selected preset declares.
          final rendered = _renderedTheme(tester);
          final presets = appearancePresetConfigsFromProjection(
            fixture.composition.binding.appearance.current,
          );
          final declared = buildLicoTheme(
            presetId: AppearancePresetIds.licoSodaLight,
            presets: presets,
            platformBrightness: Brightness.light,
          );
          expect(
            rendered.scaffoldBackgroundColor,
            isNot(backgroundBefore),
            reason: 'the restyle reached the rendered shell',
          );
          expect(
            rendered.colorScheme.primary,
            isNot(primaryBefore),
            reason: 'the restyle reached the rendered colour scheme',
          );
          expect(
            rendered.scaffoldBackgroundColor,
            declared.scaffoldBackgroundColor,
            reason:
                'the shell renders the background the selected preset declares',
          );
          expect(
            rendered.colorScheme.primary,
            declared.colorScheme.primary,
            reason: 'the shell renders the primary colour the preset declares',
          );

          final effects = <ShellEffect>[];
          // The probe stays subscribed for the rest of the measurement: the
          // composition's own disposal closes the effect stream, and releasing
          // the subscription while the shell is mounted leaves the frame
          // pipeline unable to draw another frame.
          fixture.composition.binding.effects.effects.listen(effects.add);
          fixture.selectDestination(ClientSection.agents);
          await tester.pump();
          expect(
            effects,
            isNotEmpty,
            reason:
                'the shell still delivers its business effects after a restyle',
          );
        },
      );
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );
}

/// The theme the shell is actually rendering, read from the mounted tree.
ThemeData _renderedTheme(WidgetTester tester) =>
    Theme.of(tester.element(find.byType(ClientShell)));
