import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:presentation_contract/presentation_contract.dart';
import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/composition/client_app_composition.dart';
import 'package:licoup/src/contracts/appearance/appearance_preset_config.dart';
import 'package:licoup/src/contracts/locale_preferences.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/binding/causal_frame_telemetry.dart';
import 'package:licoup/src/presentation/shell/shell_effect.dart';
import 'package:licoup/src/presentation/shell/shell_intent.dart';
import 'package:licoup/src/presentation/shell/shell_projection.dart';

import '../fixtures/client_controller/support/fake_agent_service.dart';

void main() {
  test(
    'causal telemetry is opt-in and originates composed renderer intent traces',
    () async {
      final uninstrumented = ClientAppComposition(
        controller: ClientController(),
      );
      expect(uninstrumented.telemetry, isNull);
      await uninstrumented.dispose();

      var now = 0;
      var nextTraceId = 0;
      final completed = <CausalTraceMeasurement>[];
      final telemetry = CausalFrameTelemetry(
        pendingLimit: 4,
        sampleLimit: 4,
        clock: () => now,
        traceIdFactory: () => 'composed-${nextTraceId++}',
        sink: completed.add,
      );
      final composition = ClientAppComposition(
        controller: ClientController(),
        telemetry: telemetry,
      );
      final traces = <TraceContext?>[];
      final subscription = composition.binding.navigation.changes.listen((
        update,
      ) {
        traces.add(update.trace);
        telemetry.projectionReceived(update.trace);
      });

      composition.binding.intents.send(
        const SelectShellDestination(ClientSection.settings),
      );
      expect(traces, const [TraceContext(traceId: 'composed-0')]);
      expect(telemetry.pendingCount, 1);

      now = 7;
      telemetry.frameRendered(
        buildMicroseconds: 2,
        rasterMicroseconds: 3,
        totalFrameMicroseconds: 6,
      );
      expect(completed, hasLength(1));
      expect(completed.single.origin, CausalTraceOrigin.rendererIntent);
      expect(completed.single.totalToFrameMicroseconds, 7);

      await subscription.cancel();
      await composition.dispose();
    },
  );

  test(
    'composition publishes unequal shell state and reselect effect in order',
    () async {
      final controller = ClientController();
      final composition = ClientAppComposition(controller: controller);
      final projections = <ClientSection>[];
      final effects = <ShellEffect>[];
      final projectionSubscription = composition.binding.navigation.changes
          .listen(
            (projection) => projections.add(projection.value.destination),
          );
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
      final appearances = <AppearanceProjection>[];
      final locales = <LocaleProjection>[];
      final appearanceSubscription = composition.binding.appearance.changes
          .listen((projection) => appearances.add(projection.value));
      final localeSubscription = composition.binding.locale.changes.listen(
        (projection) => locales.add(projection.value),
      );

      controller.appearancePresetId = AppearancePresetIds.licoSodaLight;
      expect(appearances, hasLength(1));
      expect(appearances.single.presetId, AppearancePresetIds.licoSodaLight);
      controller.appearancePresetId = AppearancePresetIds.licoSodaLight;
      expect(appearances, hasLength(1));

      controller.localePreference = LocalePreference.chinese;
      expect(appearances, hasLength(1));
      expect(locales, hasLength(1));
      expect(locales.single.preference, LocalePreference.chinese);
      controller.localePreference = LocalePreference.chinese;
      expect(appearances, hasLength(1));
      expect(locales, hasLength(1));

      await appearanceSubscription.cancel();
      await localeSubscription.cancel();
      await composition.dispose();
    },
  );

  test(
    'composition closes every semantic source before the controller once',
    () async {
      final events = <String>[];
      final controller = _TrackingClientController(events);
      final composition = ClientAppComposition(controller: controller);
      StreamSubscription<dynamic> track(Stream<dynamic> stream, String label) {
        return stream.listen((_) {}, onDone: () => events.add(label));
      }

      final sourceSubscriptions = <StreamSubscription<dynamic>>[
        track(composition.binding.appearance.changes, 'appearance'),
        track(composition.binding.locale.changes, 'locale'),
        track(composition.binding.layout.changes, 'layout'),
        track(composition.binding.environment.changes, 'environment'),
        track(composition.binding.navigation.changes, 'navigation'),
        track(composition.binding.status.changes, 'status'),
        track(composition.binding.effects.effects, 'shell-effects'),
        track(composition.agents.projection.changes, 'agents'),
        track(composition.agents.effects.effects, 'agents-effects'),
        track(composition.monitoring.projection.changes, 'monitoring'),
        track(composition.monitoring.effects.effects, 'monitoring-effects'),
        track(composition.conversation.projection.changes, 'conversation'),
        track(
          composition.conversation.nativeCatalog.changes,
          'conversation-native-catalog',
        ),
        track(
          composition.conversation.canonicalEvents.changes,
          'conversation-canonical-events',
        ),
        track(
          composition.conversation.persistentTurns.changes,
          'conversation-persistent-turns',
        ),
        track(
          composition.conversation.composer.changes,
          'conversation-composer',
        ),
        track(
          composition.conversation.attachments.changes,
          'conversation-attachments',
        ),
        track(
          composition.conversation.tabActivity.changes,
          'conversation-tab-activity',
        ),
        track(
          composition.conversation.notifications.changes,
          'conversation-notifications',
        ),
        track(composition.conversation.archive.changes, 'conversation-archive'),
        track(composition.conversation.effects.effects, 'conversation-effects'),
        track(composition.mobileRelay.projection.changes, 'mobile-relay'),
        track(composition.mobileRelay.effects.effects, 'mobile-relay-effects'),
        track(composition.models.projection.changes, 'models'),
        track(composition.models.effects.effects, 'models-effects'),
        track(composition.skillHub.projection.changes, 'skill-hub'),
        track(composition.skillHub.effects.effects, 'skill-hub-effects'),
        track(
          composition.pluginManagement.projection.changes,
          'plugin-management',
        ),
        track(
          composition.pluginManagement.effects.effects,
          'plugin-management-effects',
        ),
        track(composition.agentHub.projection.changes, 'agent-hub'),
        track(composition.agentHub.effects.effects, 'agent-hub-effects'),
        track(composition.targets.projection.changes, 'targets'),
        track(composition.targets.effects.effects, 'targets-effects'),
        track(composition.search.projection.changes, 'search'),
        track(composition.search.effects.effects, 'search-effects'),
        track(composition.chrome.projection.changes, 'chrome'),
        track(composition.chrome.effects.effects, 'chrome-effects'),
        track(composition.settings.projection.changes, 'settings'),
        track(
          composition.settings.resourceUsage.changes,
          'settings-resource-usage',
        ),
        track(composition.settings.autostart.changes, 'settings-autostart'),
        track(composition.settings.effects.effects, 'settings-effects'),
      ];

      await composition.dispose();
      await composition.dispose();

      expect(events.last, 'controller');
      final closedSources = events.take(events.length - 1).toList();
      expect(closedSources, hasLength(closedSources.toSet().length));
      expect(closedSources.toSet(), {
        'appearance',
        'locale',
        'layout',
        'environment',
        'navigation',
        'status',
        'shell-effects',
        'agents',
        'agents-effects',
        'monitoring',
        'monitoring-effects',
        'conversation',
        'conversation-native-catalog',
        'conversation-canonical-events',
        'conversation-persistent-turns',
        'conversation-composer',
        'conversation-attachments',
        'conversation-tab-activity',
        'conversation-notifications',
        'conversation-archive',
        'conversation-effects',
        'mobile-relay',
        'mobile-relay-effects',
        'models',
        'models-effects',
        'skill-hub',
        'skill-hub-effects',
        'plugin-management',
        'plugin-management-effects',
        'agent-hub',
        'agent-hub-effects',
        'targets',
        'targets-effects',
        'search',
        'search-effects',
        'chrome',
        'chrome-effects',
        'settings',
        'settings-resource-usage',
        'settings-autostart',
        'settings-effects',
      });
      for (final subscription in sourceSubscriptions) {
        await subscription.cancel();
      }
    },
  );
}

final class _TrackingClientController extends ClientController {
  _TrackingClientController(this.events);

  final List<String> events;

  @override
  Future<void> close() async {
    events.add('controller');
    await super.close();
  }
}
