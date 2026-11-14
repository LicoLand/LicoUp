import 'history_refresh_scenarios.dart' as refresh;
import 'history_runtime_scenarios.dart' as runtime;

export 'history_refresh_scenarios.dart';
export 'history_runtime_scenarios.dart';

/// Compatibility registration surface for all native-history scenarios.
void registerClientHistoryScenarios() {
  refresh.registerClientHistoryRefreshScenarios();
  runtime.registerClientHistoryRuntimeScenarios();
}
