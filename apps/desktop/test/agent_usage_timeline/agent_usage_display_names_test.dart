import 'package:licoup/src/contracts/agent_usage_models.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_usage_timeline/agent_usage_display_names.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('agent and model display names normalize aliases deterministically', () {
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
    expect(agentUsageModelDisplayName('openai/gpt-5.5'), 'GPT 5.5');
    expect(agentUsageModelDisplayName('deepseek_v4_pro'), 'DeepSeek V4 Pro');
    expect(agentUsageModelDisplayName('composer-2-5-fast'), 'Composer 2.5');
    expect(agentUsageModelDisplayName('composer-2.5'), 'Composer 2.5');
    expect(
      agentUsageModelLabel('{"model_name":"claude-opus-4.6"}'),
      'Claude Opus 4.6',
    );
    expect(agentUsageModelDisplayName('claude-opus-4-6'), 'Claude Opus 4.6');
  });
}
