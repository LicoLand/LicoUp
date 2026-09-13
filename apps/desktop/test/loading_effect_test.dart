import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/frontend/appearance/loading_effect_catalog.dart';
import 'package:licoup/src/frontend/shared/messaging/conversation_motion/conversation_particle_field.dart';
import 'package:licoup/src/frontend/shared/messaging/conversation_motion_surface.dart';
import 'package:licoup/src/frontend/shared/ui/lico_loading_effect.dart';
import 'package:licoup/src/frontend/shared/ui/lico_loading_indicator.dart';

void main() {
  testWidgets(
    'default empty conversation is idle and effect switches preserve draft',
    (tester) async {
      var effect = loadingEffectForId('spinner');
      late StateSetter change;
      final draft = TextEditingController(text: 'Synthetic draft');
      addTearDown(draft.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              change = setState;
              return LicoLoadingEffectScope(
                effect: effect,
                child: ConversationMotionScene(
                  conversationKey: 'synthetic-conversation',
                  visible: true,
                  assembled: false,
                  child: ConversationMotionContent(
                    child: Center(
                      child: Material(child: TextField(controller: draft)),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      );
      await tester.pump();
      final inputState = tester.state(find.byType(TextField));
      expect(find.byType(ConversationParticleField), findsNothing);
      expect(tester.binding.transientCallbackCount, 0);

      change(() => effect = loadingEffectForId('particles'));
      await tester.pump();
      await tester.pump();
      expect(find.byType(ConversationParticleField), findsOneWidget);
      expect(tester.binding.transientCallbackCount, greaterThan(0));
      expect(tester.state(find.byType(TextField)), same(inputState));

      change(() => effect = loadingEffectForId('static'));
      await tester.pump();
      await tester.pump();
      expect(find.byType(ConversationParticleField), findsNothing);
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.state(find.byType(TextField)), same(inputState));
      expect(draft.text, 'Synthetic draft');
    },
  );

  testWidgets(
    'loading renderer replaces live without rebuilding data content each tick',
    (tester) async {
      var effect = loadingEffectForId('spinner');
      var builds = 0;
      late StateSetter change;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              change = setState;
              return LicoLoadingEffectScope(
                effect: effect,
                child: Column(
                  children: [
                    Builder(
                      builder: (_) {
                        builds++;
                        return const Text('Ready data');
                      },
                    ),
                    const LicoLoadingIndicator(),
                  ],
                ),
              );
            },
          ),
        ),
      );
      final initialBuilds = builds;
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(builds, initialBuilds);
      change(
        () => effect = const LicoLoadingEffect(
          id: 'synthetic',
          englishLabel: 'Synthetic',
          chineseLabel: 'Synthetic',
          indicatorBuilder: _replacement,
          animated: false,
        ),
      );
      await tester.pump();
      expect(find.byKey(const Key('replacement')), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('Ready data'), findsOneWidget);
      expect(tester.binding.transientCallbackCount, 0);
    },
  );

  testWidgets('static, reduced and offstage loading stop scheduling frames', (
    tester,
  ) async {
    for (final state in [
      (id: 'static', reduced: false, ticking: true),
      (id: 'spinner', reduced: true, ticking: true),
      (id: 'spinner', reduced: false, ticking: false),
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: state.reduced),
            child: LicoLoadingEffectScope(
              effect: loadingEffectForId(state.id),
              child: TickerMode(
                enabled: state.ticking,
                child: const LicoLoadingIndicator(),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(tester.binding.transientCallbackCount, 0);
    }
  });
}

Widget _replacement(
  BuildContext context,
  double size,
  double stroke,
  Color? color,
) => const SizedBox(key: Key('replacement'));
