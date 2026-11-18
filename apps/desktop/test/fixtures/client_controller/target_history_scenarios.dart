import 'history_scenarios.dart' as history;
import 'target_scenarios.dart' as target;

export 'history_scenarios.dart';
export 'target_scenarios.dart';

/// Compatibility registration surface for the formerly combined scenarios.
void registerClientTargetAndHistoryScenarios() {
  target.registerClientTargetScenarios();
  history.registerClientHistoryScenarios();
}
