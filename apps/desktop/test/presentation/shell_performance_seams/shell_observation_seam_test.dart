import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/app.dart';
import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/composition/client_app_composition.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/binding/presentation_observation.dart';
import 'package:licoup/src/frontend/binding/projection_telemetry_scope.dart';
import 'package:licoup/src/presentation/shell/shell_intent.dart';

import '../../fixtures/client_controller/support/fake_agent_service.dart';
import 'support/counted_shell_observation.dart';
import 'support/shell_seam_fixture.dart';

/// The composition installs one presentation observation owner, and the real
/// shell reports its ordinary interactions to it.
///
/// The counted owner is installed exactly where production installs its own
/// telemetry, so a shell that stopped reporting - or a composition that
/// silently stopped installing an owner - fails here instead of in a profile
/// run.
void main() {
  testWidgets(
    'a counted owner installed by the composition counts one navigation response',
    (tester) async {
      final observation = CountedShellObservation();
      final fixture = await ShellSeamFixture.create(
        tester,
        observation: observation,
      );

      final measurement = await fixture.measure(
        'navigation-switch',
        () async => fixture.selectDestination(ClientSection.settings),
        observation: observation,
      );

      expect(fixture.currentSection, ClientSection.settings);
      expect(
        measurement.acceptedProjections,
        1,
        reason: 'only the navigation projection changed for this interaction',
      );
      expect(
        measurement.rendererIntents,
        greaterThanOrEqualTo(1),
        reason: 'the shell began a renderer intent for its own interaction',
      );
      expect(
        measurement.frameConsumedProjections,
        greaterThanOrEqualTo(1),
        reason: 'a pumped frame consumed the projection it rebuilt for',
      );
      expect(
        measurement.consumedFrames,
        1,
        reason: 'one interaction is consumed by one pumped frame',
      );
      expect(
        observation.unavailableCounts[CausalTelemetryUnavailableReason
            .capacityEvicted],
        isNull,
        reason: 'a bounded owner never evicted a trace under this interaction',
      );

      await fixture.dispose();
    },
  );

  testWidgets('a composition that installs no owner records nothing', (
    tester,
  ) async {
    final controller = ClientController(agentService: FakeAgentService());
    final composition = ClientAppComposition(controller: controller);
    expect(
      composition.telemetry,
      isNull,
      reason: 'observation is opt-in; the default composition installs none',
    );
    await tester.runAsync(controller.layoutManager.initialize);
    controller
      ..statusCaption = 'Ready'
      ..statusMessage = 'Ready.';
    await tester.pumpWidget(
      LicoApp(
        compositionFactory: () => composition,
        initializeController: false,
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(
      find.byType(ProjectionTelemetryScope),
      findsNothing,
      reason: 'without an installed owner no renderer scope is created',
    );

    composition.binding.intents.send(
      const SelectShellDestination(ClientSection.settings),
    );
    await tester.pump();
    await tester.pump();

    expect(
      controller.currentSection,
      ClientSection.settings,
      reason: 'the interaction still works without any observation installed',
    );
    expect(find.byType(MaterialApp), findsOneWidget);

    await tester.runAsync(composition.dispose);
  });

  test('an installed owner is the only owner of the phase facts it retains', () {
    final observation = CountedShellObservation();
    expect(observation.pendingTraceCount, 0);
    expect(observation.frameSamples, 0);

    final trace = observation.projectionEmitted();
    observation.flutterReceived(trace);
    expect(observation.projectionEmissions, 1);
    expect(observation.pendingTraceCount, 1);

    observation.dispose();
    observation.dispose();
    expect(observation.pendingTraceCount, 0);
    expect(observation.disposed, isTrue);
    expect(trace.traceId, isNotNull);
  });
}
