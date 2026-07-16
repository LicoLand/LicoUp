import 'local_management/conversation_archive_scenarios.dart';
import 'local_management/skill_management_scenarios.dart';
import 'local_management/target_management_scenarios.dart';
import 'support/client_controller_scenario_dependencies.dart';

void registerClientLocalManagementScenarios() {
  TestWidgetsFlutterBinding.ensureInitialized();
  registerClientConversationArchiveScenarios();
  registerClientTargetManagementScenarios();
  registerClientSkillManagementScenarios();
}
