import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/shell/client_shell.dart';

import 'support/counted_shell_observation.dart';
import 'support/shell_interaction_workload.dart';
import 'support/shell_regression_probes.dart';
import 'support/shell_seam_fixture.dart';

/// The registered budget has teeth: the defect fixtures fail it.
///
/// Both fixtures are mounted over the real shell through the production root's
/// renderer seam. Each one violates the same registered condition the healthy
/// shell satisfies, so the owning check fails when the defect is present
/// instead of depending on a bespoke assertion.
void main() {
  testWidgets('a global subscriber breaks the counted response budget', (
    tester,
  ) async {
    final workload = ShellInteractionWorkload.load();
    resetGlobalSubscriptionProbe();
    final observation = CountedShellObservation();
    final fixture = await ShellSeamFixture.create(
      tester,
      observation: observation,
      homeBuilder: (context, binding, renderer) => GlobalSubscriptionProbe(
        binding: binding,
        child: ClientShell(binding: binding, renderer: renderer),
      ),
    );

    final measurement = await fixture.measure(
      'navigation-switch',
      () async => fixture.selectDestination(ClientSection.settings),
      observation: observation,
    );

    expect(
      measurement.acceptedProjections,
      greaterThan(
        workload.entry('navigation-switch').limits['acceptedProjections']!,
      ),
      reason: 'the global subscriber accepts updates the region does not own',
    );
    expect(
      workload.entry('navigation-switch').violationsFor(measurement),
      isNotEmpty,
      reason: 'the registered condition must reject the global subscriber',
    );

    await fixture.dispose();
  });

  testWidgets('per-frame UI work breaks the counted rebuild budget', (
    tester,
  ) async {
    final workload = ShellInteractionWorkload.load();
    final observation = CountedShellObservation();
    final fixture = await ShellSeamFixture.create(
      tester,
      observation: observation,
      homeBuilder: (context, binding, renderer) => UiWorkProbe(
        child: ClientShell(binding: binding, renderer: renderer),
      ),
    );

    final measurement = await fixture.measure(
      'navigation-reselect',
      () async => fixture.selectDestination(ClientSection.settings),
      observation: observation,
    );

    expect(
      measurement.totalRebuilds,
      greaterThan(workload.entry('navigation-reselect').limits['rebuilds']!),
      reason: 'the probe rebuilds a wide subtree on every pumped frame',
    );
    expect(
      workload.entry('navigation-reselect').violationsFor(measurement),
      isNotEmpty,
      reason: 'the registered condition must reject the per-frame UI work',
    );

    await fixture.dispose();
  });
}
