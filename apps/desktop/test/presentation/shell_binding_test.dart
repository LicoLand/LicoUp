import 'package:flutter_test/flutter_test.dart';
import 'package:presentation_contract/presentation_contract.dart';
import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/composition/client_app_composition.dart';
import 'package:licoup/src/contracts/appearance/appearance_preset_config.dart';
import 'package:licoup/src/contracts/locale_preferences.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/presentation/shell/shell_effect.dart';
import 'package:licoup/src/presentation/shell/shell_intent.dart';
import 'package:licoup/src/presentation/shell/shell_projection.dart';

import '../fixtures/client_controller/support/fake_agent_service.dart';

void main() {
  test(
    'composition publishes unequal shell state and reselect effect in order',
    () async {
      final controller = ClientController();
      final composition = ClientAppComposition(controller: controller);
      final projections = <ClientSection>[];
      final effects = <ShellEffect>[];
      final projectionSubscription = composition.binding.projection.changes
          .listen((projection) => projections.add(projection.destination));
      final effectSubscription = composition.binding.effects.effects.listen(
        effects.add,
      );

      composition.binding.intents.send(
        const SelectShellDestination(
          ClientSection.agents,
          trace: TraceContext(traceId: 'local-test-trace'),
        ),
      );
      expect(effects, hasLength(1));
      final reselected = effects.single as ShellDestinationReselected;
      expect(reselected.destination, ClientSection.agents);
      expect(reselected.trace, const TraceContext(traceId: 'local-test-trace'));
      expect(projections, isEmpty);

      composition.binding.intents.send(
        const SelectShellDestination(ClientSection.settings),
      );
      expect(projections, <ClientSection>[ClientSection.settings]);

      await projectionSubscription.cancel();
      await effectSubscription.cancel();
      await composition.dispose();
      await composition.dispose();
    },
  );

  test(
    'open-agent intent starts selection once before navigating once',
    () async {
      final controller = ClientController(agentService: FakeAgentService());
      final composition = ClientAppComposition(controller: controller);

      composition.binding.intents.send(const OpenShellAgent('codex'));

      expect(controller.selectedConversationAgentId, 'codex');
      expect(controller.currentSection, ClientSection.agents);

      await composition.dispose();
    },
  );

  test(
    'appearance and locale publish only unequal focused projections',
    () async {
      final controller = ClientController();
      final composition = ClientAppComposition(controller: controller);
      final appearances = <ShellAppearance>[];
      final subscription = composition.binding.projection.changes.listen(
        (projection) => appearances.add(projection.appearance),
      );

      controller.appearancePresetId = AppearancePresetIds.licoSodaLight;
      expect(appearances, hasLength(1));
      expect(appearances.single.presetId, AppearancePresetIds.licoSodaLight);
      controller.appearancePresetId = AppearancePresetIds.licoSodaLight;
      expect(appearances, hasLength(1));

      controller.localePreference = LocalePreference.chinese;
      expect(appearances, hasLength(2));
      expect(appearances.last.localePreference, LocalePreference.chinese);
      controller.localePreference = LocalePreference.chinese;
      expect(appearances, hasLength(2));

      await subscription.cancel();
      await composition.dispose();
    },
  );

  test(
    'composition closes focused sources before the controller once',
    () async {
      final events = <String>[];
      final controller = _TrackingClientController(events);
      final composition = ClientAppComposition(controller: controller);
      composition.binding.projection.changes.listen(
        (_) {},
        onDone: () => events.add('projection'),
      );
      composition.binding.effects.effects.listen(
        (_) {},
        onDone: () => events.add('effects'),
      );

      await composition.dispose();
      await composition.dispose();

      expect(events, <String>['projection', 'effects', 'controller']);
    },
  );
}

final class _TrackingClientController extends ClientController {
  _TrackingClientController(this.events);

  final List<String> events;

  @override
  void dispose() {
    events.add('controller');
    super.dispose();
  }
}
