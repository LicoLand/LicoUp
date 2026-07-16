import 'package:flutter_client/src/contracts/agent_usage_models.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/agent_usage_timeline/agent_usage_display_names.dart';
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

    expect(agentUsageAgentDisplayName(known), 'ChatGPT - Desktop');
    expect(agentUsageAgentDisplayName(fallback), 'Custom agent');
    expect(agentUsageModelDisplayName('openai/gpt-5.5'), 'GPT 5.5');
    expect(agentUsageModelDisplayName('deepseek_v4_pro'), 'DeepSeek V4 Pro');
    expect(
      agentUsageModelDisplayName('composer-2-5-fast'),
      'Composer 2.5 Fast',
    );
    expect(
      agentUsageModelLabel('{"model_name":"claude-opus-4.6"}'),
      'Claude Opus 4.6',
    );
  });
}
