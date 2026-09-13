import 'package:licoup/src/frontend/features/agents/ui/agent_usage_timeline/agent_usage_token_breakdown.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'token breakdown preserves exact, missing-cache, and merge semantics',
    () {
      final exact = agentUsageTokenBreakdown(const {
        'promptTokens': 100,
        'cachedInputTokens': 40,
        'completionTokens': 20,
        'totalTokens': 120,
      }, totalTokens: 120);
      final missingCache = agentUsageTokenBreakdown(const {
        'input_tokens': 30,
        'output_tokens': 10,
      }, totalTokens: 40);
      final estimated = agentUsageTokenBreakdown(const {
        'promptTokens': 30,
        'completionTokens': 10,
      }, totalTokens: 80);
      final models = agentUsageModelUsageMap(const {
        'modelTokenUsage': {
          'openai/gpt-5.5': {'displayName': 'GPT-5.5', 'totalTokens': 500},
          'GPT_5.5': {'displayName': 'GPT-5.5', 'totalTokens': 50},
        },
      });

      expect(exact.isExact, isTrue);
      expect(exact.cachedInputTokens, 40);
      expect(missingCache.isExact, isTrue);
      expect(missingCache.cachedInputTokens, 0);
      expect(estimated.isExact, isFalse);
      expect(models.keys, ['openai/gpt-5.5', 'GPT_5.5']);
      expect(models['openai/gpt-5.5']?.totalTokens, 500);
      expect(models['GPT_5.5']?.totalTokens, 50);
      expect(models['openai/gpt-5.5']?.displayName, 'GPT-5.5');
      expect(models['openai/gpt-5.5']?.breakdown.isExact, isFalse);
    },
  );
}
