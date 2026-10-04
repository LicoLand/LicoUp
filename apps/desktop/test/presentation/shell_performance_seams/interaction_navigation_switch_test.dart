import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/features/agents/ui/agents_canvas.dart';

import 'support/interaction_measurement.dart';

/// The navigation-switch interaction is measured and checked against the
/// registered workload definition.
///
/// The measurement counts the work the real shell performed for the action the
/// user performed, and it also asserts the result: the destination the user
/// selected is the destination the shell is showing.
void main() {
  testWidgets(
    'navigation-switch stays inside the registered budget',
    (tester) async {
      await measureInteraction(
        tester,
        'navigation-switch',
        act: (fixture) async =>
            fixture.selectDestination(ClientSection.settings),
        verify: (tester, fixture) {
          expect(
            fixture.currentSection,
            ClientSection.settings,
            reason: 'the navigation interaction really changed the destination',
          );
          expect(
            find.byType(AgentsCanvas),
            findsNothing,
            reason: 'the shell stopped rendering the agents destination',
          );
        },
      );
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
