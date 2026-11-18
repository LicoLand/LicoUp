import 'client_controller_scenario_dependencies.dart';
import 'fake_agent_archive_support.dart';
import 'fake_agent_conversation_support.dart';
import 'fake_agent_runtime_support.dart';
import 'fake_agent_state_support.dart';
import 'fake_agent_usage_support.dart';

class FakeAgentService extends AgentService
    with
        FakeAgentStateSupport,
        FakeAgentConversationSupport,
        FakeAgentRuntimeSupport,
        FakeAgentArchiveSupport,
        FakeAgentUsageSupport {
  @override
  Future<Map<String, dynamic>> runCli(List<String> args) async {
    cliCalls = [...cliCalls, List<String>.from(args)];

    if (args.isNotEmpty) {
      Map<String, dynamic>? result;
      switch (args.first) {
        case 'agent-usage':
          result = await handleFakeAgentUsageCli(args);
          break;
        case 'conversations':
          result = await handleFakeAgentConversationCli(args);
          break;
        case 'snapshots':
          result = await handleFakeAgentArchiveCli(args);
          break;
      }
      if (result != null) {
        return result;
      }
    }
    return {'ok': true};
  }
}
