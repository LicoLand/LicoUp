import 'client_controller_scenario_dependencies.dart';
import 'fake_agent_state_support.dart';

mixin FakeAgentUsageSupport on AgentService, FakeAgentStateSupport {
  int agentUsageScanCalls = 0;
  int agentUsageReportCalls = 0;

  String agentUsageAgent = '';

  Map<String, dynamic> agentUsageScanResult = {
    'ok': true,
    'schemaVersion': AgentUsageReport.currentSchemaVersion,
    'mode': AgentUsageReport.currentMode,
    'tokenSourceMode': AgentUsageReport.currentTokenSourceMode,
    'generatedAt': '2026-06-28T00:00:00Z',
    'summary': {'agentCount': 1, 'totalTokens': 42, 'confidence': 'medium'},
    'agents': [
      {
        'agentId': 'codex',
        'label': 'Codex',
        'status': 'detected',
        'history': {'sessionCount': 2, 'messageCount': 4, 'totalTokens': 42},
        'confidence': 'medium',
      },
    ],
  };
  Object? agentUsageReportsResult;

  Completer<void>? agentUsageScanGate;
  Completer<void>? agentUsageReportGate;

  Future<Map<String, dynamic>?> handleFakeAgentUsageCli(
    List<String> args,
  ) async {
    if (args.length >= 2 && args[0] == 'agent-usage') {
      switch (args[1]) {
        case 'scan':
          agentUsageScanCalls++;
          agentUsageAgent = fakeAgentArgValue(args, '--agent');
          final scanGate = agentUsageScanGate;
          if (scanGate != null) {
            await scanGate.future;
          }
          return agentUsageScanResult;
        case 'report':
          agentUsageReportCalls++;
          final reportGate = agentUsageReportGate;
          if (reportGate != null) {
            await reportGate.future;
          }
          return {
            'ok': true,
            'schemaVersion': AgentUsageReport.currentSchemaVersion,
            'mode': AgentUsageReport.currentMode,
            'tokenSourceMode': AgentUsageReport.currentTokenSourceMode,
            'reports': agentUsageReportsResult ?? [agentUsageScanResult],
          };
      }
    }
    return null;
  }
}
