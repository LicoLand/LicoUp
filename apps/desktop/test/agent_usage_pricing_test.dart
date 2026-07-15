import 'package:flutter_client/src/frontend/features/agents/ui/agent_usage_pricing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('standard API pricing separates cached input from regular input', () {
    final estimate = AgentUsageApiPricing.estimate(
      model: 'openai/gpt-5.5-2026-04-23',
      usage: const AgentUsageTokenBreakdown(
        promptTokens: 1000000,
        cachedInputTokens: 200000,
        completionTokens: 100000,
        totalTokens: 1100000,
        isExact: true,
      ),
    );

    expect(estimate.usd, closeTo(7.1, 0.0000001));
  });

  test('formal display labels resolve to the maintained model rate keys', () {
    expect(AgentUsageApiPricing.rateFor('GPT 5.6 Sol')?.modelId, 'gpt-5.6-sol');
    expect(
      AgentUsageApiPricing.rateFor('Claude Opus 4.6')?.modelId,
      'claude-opus-4.6',
    );
    expect(
      AgentUsageApiPricing.rateFor('claude-opus-4-6-2026-02-05')?.modelId,
      'claude-opus-4.6',
    );
    expect(
      AgentUsageApiPricing.rateFor('DeepSeek V4 Pro')?.modelId,
      'deepseek-v4-pro',
    );
    expect(AgentUsageApiPricing.rateFor('kimi-k2.5')?.modelId, 'kimi-k2.5');
    expect(
      AgentUsageApiPricing.rateFor('Claude Sonnet 4')?.modelId,
      'claude-sonnet-4',
    );
    expect(
      AgentUsageApiPricing.rateFor('gemini-2.5-flash')?.modelId,
      'gemini-2.5-flash',
    );
  });

  test('unknown prices and total-only usage stay unavailable', () {
    const exact = AgentUsageTokenBreakdown(
      promptTokens: 100,
      cachedInputTokens: 0,
      completionTokens: 20,
      totalTokens: 120,
      isExact: true,
    );
    const totalOnly = AgentUsageTokenBreakdown.unavailable(totalTokens: 120);

    expect(
      AgentUsageApiPricing.estimate(
        model: 'gpt-5.3-codex-spark',
        usage: exact,
      ).isAvailable,
      isFalse,
    );
    expect(
      AgentUsageApiPricing.estimate(
        model: 'gpt-5.5',
        usage: totalOnly,
      ).isAvailable,
      isTrue,
    );
    expect(
      AgentUsageApiPricing.estimate(model: 'gpt-5.5', usage: totalOnly).usd,
      closeTo(120 * 0.75 * 5 / 1000000 + 120 * 0.25 * 30 / 1000000, 0.0000001),
    );
    expect(
      AgentUsageApiPricing.estimate(model: 'Others', usage: exact).isAvailable,
      isFalse,
    );
  });
}
