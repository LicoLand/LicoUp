import 'package:licoup/src/contracts/agent_usage_models.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_usage_timeline/agent_usage_display_names.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('agent product display names preserve their existing presentation', () {
    const known = AgentUsageAgentSummary(
      agentId: 'codex',
      label: 'Codex',
      status: 'detected',
      history: {},
      confidence: 'high',
    );
    const fallback = AgentUsageAgentSummary(
      agentId: 'custom_agent',
      label: '',
      status: 'detected',
      history: {},
      confidence: 'high',
    );
    const codexCli = AgentUsageAgentSummary(
      agentId: 'codex-cli',
      label: 'Codex - CLI',
      status: 'detected',
      history: {},
      confidence: 'high',
    );
    const kimiCodePlugin = AgentUsageAgentSummary(
      agentId: 'kimi-code-plugin',
      label: 'Kimi Code - Plugin',
      status: 'detected',
      history: {},
      confidence: 'high',
    );

    expect(agentUsageAgentDisplayName(known), 'Codex');
    expect(agentUsageAgentDisplayName(codexCli), 'Codex');
    expect(agentUsageAgentDisplayName(kimiCodePlugin), 'Kimi Code');
    expect(agentUsageAgentDisplayName(fallback), 'Custom agent');
  });
}
