import 'package:flutter_client/src/contracts/agent_usage_models.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/agent_usage_timeline/agent_usage_visibility_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'visibility excludes aliases while retaining meaningful local usage',
    () {
      const alias = AgentUsageAgentSummary(
        agentId: 'vscode',
        label: 'VS Code',
        status: 'detected',
        history: {'totalTokens': 20},
        confidence: 'high',
      );
      const pending = AgentUsageAgentSummary(
        agentId: 'cursor',
        label: 'Cursor',
        status: 'pending',
        history: {},
        confidence: '',
      );
      const historical = AgentUsageAgentSummary(
        agentId: 'cursor',
        label: 'Cursor',
        status: 'pending',
        history: {'totalTokens': 12},
        confidence: 'estimated',
      );
      const retired = AgentUsageAgentSummary(
        agentId: 'codex',
        label: 'Codex',
        status: 'not-detected',
        history: {'totalTokens': 100},
        confidence: 'estimated',
      );

      expect(shouldShowAgentUsage(alias, const {'vscode'}), isFalse);
      expect(shouldShowAgentUsage(pending, const {'codex'}), isFalse);
      expect(shouldShowAgentUsage(historical, const {'codex'}), isTrue);
      expect(shouldShowAgentUsage(historical, const {}), isTrue);
      expect(shouldShowAgentUsage(retired, const {'codex'}), isFalse);
    },
  );

  test('detected aliases retain unavailable usage rows', () {
    const copilot = AgentUsageAgentSummary(
      agentId: 'copilot',
      label: 'GitHub Copilot',
      status: 'unknown',
      history: {},
      confidence: 'unavailable',
    );
    const unknown = AgentUsageAgentSummary(
      agentId: 'openclaw',
      label: 'OpenClaw',
      status: 'unknown',
      history: {},
      confidence: 'unavailable',
    );

    expect(shouldShowAgentUsage(copilot, const {'github-copilot'}), isTrue);
    expect(shouldShowAgentUsage(unknown, const {}), isFalse);
  });
}
