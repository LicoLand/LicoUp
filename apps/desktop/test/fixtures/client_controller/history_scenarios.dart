import 'history_refresh_scenarios.dart' as refresh;
import 'history_runtime_scenarios.dart' as runtime;
import 'mobile_history_scenarios.dart' as mobile;

export 'history_refresh_scenarios.dart';
export 'history_runtime_scenarios.dart';
export 'mobile_history_scenarios.dart';

/// Compatibility registration surface for all native-history scenarios.
void registerClientHistoryScenarios() {
  mobile.registerClientMobileHistoryScenarios();
  refresh.registerClientHistoryRefreshScenarios();
  runtime.registerClientHistoryRuntimeScenarios();
}
