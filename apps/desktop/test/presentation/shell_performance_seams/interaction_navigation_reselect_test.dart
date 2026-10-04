import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/features/agents/ui/agents_canvas.dart';

import 'support/interaction_measurement.dart';

/// The navigation-reselect interaction is measured and checked against the
/// registered workload definition.
///
/// The measurement counts the work the real shell performed for the action the
/// user performed: projection responses a rendering region accepted, the frame
/// that consumed them, and the widget rebuilds the interaction caused. The
/// destination is selected on its own first, because the counted window opens
/// after the shell already shows it.
void main() {
  testWidgets(
    'navigation-reselect stays inside the registered budget',
    (tester) async {
      await measureInteraction(
        tester,
        'navigation-reselect',
        arrange: (fixture) async =>
            fixture.selectDestination(ClientSection.settings),
        act: (fixture) async =>
            fixture.selectDestination(ClientSection.settings),
        verify: (tester, fixture) {
          expect(
            fixture.currentSection,
            ClientSection.settings,
            reason: 'reselecting the shown destination keeps the shell there',
          );
          expect(
            find.byType(AgentsCanvas),
            findsNothing,
            reason: 'the shell still renders the destination it already showed',
          );
        },
      );
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
