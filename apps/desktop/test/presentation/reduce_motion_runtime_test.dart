import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/app.dart';
import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/composition/client_app_composition.dart';
import 'package:licoup/src/contracts/appearance/appearance_preset_config.dart';
import 'package:licoup/src/contracts/presentation/presentation_preferences.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion_scope.dart';
import 'package:licoup/src/presentation/shell/shell_intent.dart';

void main() {
  testWidgets(
    'manual preference overrides the system and follow-system combines both sources',
    (tester) async {
      for (final system in [false, true]) {
        for (final native in [false, true]) {
          for (final manual in ReduceMotionPreference.values) {
            bool? effective;
            await tester.pumpWidget(
              MediaQuery(
                data: MediaQueryData(disableAnimations: system),
                child: LicoMotionScope(
                  reduceMotion: manual,
                  systemReduceMotion: native,
                  child: Builder(
                    builder: (context) {
                      effective = MediaQuery.disableAnimationsOf(context);
                      return const SizedBox();
                    },
                  ),
                ),
              ),
            );
            expect(effective, switch (manual) {
              ReduceMotionPreference.on => true,
              ReduceMotionPreference.off => false,
              ReduceMotionPreference.system => system || native,
            });
          }
        }
      }
    },
    variant: TargetPlatformVariant.all(),
  );

  testWidgets(
    'native changes preserve functional state and environment',
    (tester) async {
      final events = StreamController<bool>.broadcast(sync: true);
      final controller = ClientController();
      controller.appearancePreferenceOwner.replaceReduceMotion(
        ReduceMotionPreference.system,
      );
      final composition = ClientAppComposition(
        controller: controller,
        systemReduceMotionChanges: events.stream,
      );
      final stateKey = GlobalKey<_FunctionalStateProbeState>();
      await tester.pumpWidget(
        LicoApp(
          compositionFactory: () => composition,
          initializeController: false,
          homeBuilder: (_, _, _) => _FunctionalStateProbe(key: stateKey),
        ),
      );
      final functionalState = stateKey.currentState!;
      await tester.enterText(find.byType(TextField), 'Draft remains');
      expect(functionalState.reduced, isFalse);

      events.add(true);
      await tester.pump();
      expect(functionalState.reduced, isTrue);
      expect(
        composition.binding.environment.current.systemReduceMotion,
        isTrue,
      );

      composition.binding.intents.send(
        UpdateShellLayoutEnvironment(
          composition.binding.environment.current.environment,
        ),
      );
      controller.appearancePresetId = AppearancePresetIds.taroWaffle;
      await tester.pump();
      expect(stateKey.currentState, same(functionalState));
      expect(functionalState.draft.text, 'Draft remains');
      expect(functionalState.reduced, isTrue);
      expect(
        composition.binding.environment.current.systemReduceMotion,
        isTrue,
      );

      events.add(false);
      await tester.pump();
      expect(functionalState.reduced, isFalse);
      expect(functionalState.draft.text, 'Draft remains');
      await tester.runAsync(composition.dispose);
      await tester.pumpWidget(const SizedBox());
      expect(events.hasListener, isFalse);
      await events.close();
    },
    variant: TargetPlatformVariant({TargetPlatform.macOS}),
  );

  testWidgets('manual preference updates the running app', (tester) async {
    final controller = ClientController();
    final composition = ClientAppComposition(controller: controller);
    final stateKey = GlobalKey<_FunctionalStateProbeState>();
    await tester.pumpWidget(
      LicoApp(
        compositionFactory: () => composition,
        initializeController: false,
        homeBuilder: (_, _, _) => _FunctionalStateProbe(key: stateKey),
      ),
    );
    final functionalState = stateKey.currentState!;
    expect(functionalState.reduced, isFalse);
    controller.appearancePreferenceOwner.replaceReduceMotion(
      ReduceMotionPreference.on,
    );
    await tester.pump();
    expect(functionalState.reduced, isTrue);
    expect(stateKey.currentState, same(functionalState));
    controller.appearancePreferenceOwner.replaceReduceMotion(
      ReduceMotionPreference.off,
    );
    await tester.pump();
    expect(functionalState.reduced, isFalse);
    await tester.runAsync(composition.dispose);
    await tester.pumpWidget(const SizedBox());
  });
}

class _FunctionalStateProbe extends StatefulWidget {
  const _FunctionalStateProbe({super.key});

  @override
  State<_FunctionalStateProbe> createState() => _FunctionalStateProbeState();
}

class _FunctionalStateProbeState extends State<_FunctionalStateProbe> {
  final draft = TextEditingController();
  bool reduced = false;

  @override
  Widget build(BuildContext context) {
    reduced = MediaQuery.disableAnimationsOf(context);
    return Scaffold(body: TextField(controller: draft));
  }

  @override
  void dispose() {
    draft.dispose();
    super.dispose();
  }
}
