import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/features/agents/ui/agents_canvas.dart';

import 'support/interaction_measurement.dart';

/// The layout-change interaction is measured and checked against the
/// registered workload definition.
///
/// The measurement counts the work the real shell performed for the action the
/// user performed: projection responses a rendering region accepted, the frame
/// that consumed them, and the widget rebuilds the interaction caused. The
/// destination is selected on its own first, so the layout change is measured
/// while the shell is showing a destination it must not navigate away from.
void main() {
  testWidgets(
    'layout-change stays inside the registered budget',
    (tester) async {
      await measureInteraction(
        tester,
        'layout-change',
        arrange: (fixture) async =>
            fixture.selectDestination(ClientSection.agents),
        act: (fixture) async => fixture.switchLayout(),
        verify: (tester, fixture) {
          expect(
            fixture.currentLayoutId.value,
            'desktop',
            reason:
                'the layout interaction really changed the stored selection',
          );
          expect(
            fixture.currentSection,
            ClientSection.agents,
            reason: 'a layout change does not navigate the shell',
          );
          expect(
            find.byType(AgentsCanvas),
            findsOneWidget,
            reason: 'the shell still renders the destination it was showing',
          );
        },
      );
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
