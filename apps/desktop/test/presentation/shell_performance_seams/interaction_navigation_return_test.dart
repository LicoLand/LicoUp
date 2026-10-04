import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/features/agents/ui/agents_canvas.dart';

import 'support/interaction_measurement.dart';

/// The navigation-return interaction is measured and checked against the
/// registered workload definition.
///
/// The measurement counts the work the real shell performed for the action the
/// user performed: projection responses a rendering region accepted, the frame
/// that consumed them, and the widget rebuilds the interaction caused. The
/// other destination is selected on its own first, so the counted window opens
/// on the return the user performs.
void main() {
  testWidgets(
    'navigation-return stays inside the registered budget',
    (tester) async {
      await measureInteraction(
        tester,
        'navigation-return',
        arrange: (fixture) async =>
            fixture.selectDestination(ClientSection.settings),
        act: (fixture) async => fixture.selectDestination(ClientSection.agents),
        verify: (tester, fixture) {
          expect(
            fixture.currentSection,
            ClientSection.agents,
            reason: 'the navigation interaction really changed the destination',
          );
          expect(
            find.byType(AgentsCanvas),
            findsOneWidget,
            reason: 'the shell renders the destination the user returned to',
          );
        },
      );
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
