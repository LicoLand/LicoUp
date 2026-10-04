import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'counted_shell_observation.dart';
import 'shell_interaction_workload.dart';
import 'shell_seam_fixture.dart';

/// Measures one named ordinary shell interaction and checks it against its
/// registered workload entry.
///
/// One interaction is measured per test process: the counted phases are read
/// from the real composition, and a measurement that runs after other mounted
/// shells in the same process is not reproducible, so each suite owns its
/// process and its own budget.
///
/// [arrange] stages the state the interaction starts from and is measured on
/// its own, because the counted window opens after it. [act] is the ordinary
/// action the user performs. [verify] runs while the measured shell is still
/// mounted, so an interaction can also assert the state it left behind.
Future<void> measureInteraction(
  WidgetTester tester,
  String interaction, {
  Future<void> Function(ShellSeamFixture fixture)? arrange,
  required Future<void> Function(ShellSeamFixture fixture) act,
  FutureOr<void> Function(WidgetTester tester, ShellSeamFixture fixture)?
  verify,
}) async {
  final workload = ShellInteractionWorkload.load();
  final observation = CountedShellObservation();
  final fixture = await ShellSeamFixture.create(
    tester,
    observation: observation,
  );
  if (arrange != null) {
    await arrange(fixture);
    await tester.pump();
    await tester.pump();
  }

  final measurement = await fixture.measure(
    interaction,
    () async => act(fixture),
    observation: observation,
  );

  expect(
    workload.declares(measurement.interaction),
    isTrue,
    reason:
        '${measurement.interaction} is not registered in the workload '
        'definition, so nothing would catch its regression',
  );
  final entry = workload.entry(measurement.interaction);
  expect(
    entry.violationsFor(measurement),
    isEmpty,
    reason: '${measurement.interaction} measured $measurement',
  );
  expect(
    measurement.totalRebuilds,
    greaterThan(0),
    reason:
        '${measurement.interaction} must do visible work; a zero count '
        'means the measurement stopped observing, not that work vanished',
  );
  if (verify != null) await verify(tester, fixture);

  await fixture.dispose();
}
