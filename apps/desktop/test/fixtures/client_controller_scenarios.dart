import 'client_controller/bootstrap_scenarios.dart' as bootstrap;
import 'client_controller/conversation_dispatch_scenarios.dart' as dispatch;
import 'client_controller/local_management_scenarios.dart' as local;
import 'client_controller/routing_scenarios.dart' as routing;
import 'client_controller/secure_mesh_scenarios.dart' as secure_mesh;
import 'client_controller/target_history_scenarios.dart' as target_history;

export 'client_controller/bootstrap_scenarios.dart';
export 'client_controller/conversation_dispatch_scenarios.dart';
export 'client_controller/local_management_scenarios.dart';
export 'client_controller/routing_scenarios.dart';
export 'client_controller/secure_mesh_scenarios.dart';
export 'client_controller/target_history_scenarios.dart';

/// Compatibility registration surface for callers that intentionally run the
/// complete controller scenario set.
void registerClientControllerScenarios() {
  bootstrap.registerClientBootstrapScenarios();
  target_history.registerClientTargetAndHistoryScenarios();
  dispatch.registerClientConversationDispatchScenarios();
  routing.registerClientRoutingScenarios();
  local.registerClientLocalManagementScenarios();
  secure_mesh.registerClientSecureMeshScenarios();
}
