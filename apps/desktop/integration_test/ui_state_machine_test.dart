import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../test/ui_state_machine/model.dart';
import '../test/ui_state_machine/runner.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // Let the engine schedule animation/input frames naturally. Forced test
  // frames can stall a live run and would distort the performance sample.
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.benchmarkLive;
  final model = UiInteractionModel.load();
  final run = UiInteractionRun(model, performance: true);
  for (final machine in model.machines.where(run.selects)) {
    testWidgets('${machine.id}: visible transitions and frames', (
      tester,
    ) async {
      // Profile builds require a registered test keyboard for enterText to
      // address the active input client. Rendering still uses the real engine.
      binding.testTextInput.register();
      try {
        await run.exercise(tester, machine);
      } finally {
        binding.testTextInput.unregister();
        binding.reportData = run.report();
      }
    });
  }
}
