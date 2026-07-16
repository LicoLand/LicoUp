import 'agent_usage_display_names.dart';
import 'agent_usage_source_parser.dart';

class AgentUsageModelTokens {
  const AgentUsageModelTokens({
    required this.totalTokens,
    required this.breakdown,
  });

  final double totalTokens;
  final AgentUsageTokenBreakdown breakdown;

  AgentUsageModelTokens merge(AgentUsageModelTokens other) {
    return AgentUsageModelTokens(
      totalTokens: totalTokens + other.totalTokens,
      breakdown: breakdown.merge(other.breakdown),
    );
  }

  AgentUsageModelTokens withBreakdown(AgentUsageTokenBreakdown value) {
    return AgentUsageModelTokens(totalTokens: totalTokens, breakdown: value);
  }
}

class AgentUsageTokenBreakdown {
  const AgentUsageTokenBreakdown({
    required this.promptTokens,
    required this.cachedInputTokens,
    required this.completionTokens,
    required this.totalTokens,
    required this.isExact,
  });

  const AgentUsageTokenBreakdown.unavailable({required this.totalTokens})
    : promptTokens = 0,
      cachedInputTokens = 0,
      completionTokens = 0,
      isExact = false;

  final double promptTokens;
  final double cachedInputTokens;
  final double completionTokens;
  final double totalTokens;
  final bool isExact;

  AgentUsageTokenBreakdown merge(AgentUsageTokenBreakdown other) {
    return AgentUsageTokenBreakdown(
      promptTokens: promptTokens + other.promptTokens,
      cachedInputTokens: cachedInputTokens + other.cachedInputTokens,
      completionTokens: completionTokens + other.completionTokens,
      totalTokens: totalTokens + other.totalTokens,
      isExact: isExact && other.isExact,
    );
  }
}

Map<String, AgentUsageModelTokens> agentUsageModelUsageMap(Object? source) {
  final values = <String, AgentUsageModelTokens>{};
  if (source is List) {
    mergeAgentUsageModelValues(values, source);
    return values;
  }
  if (source is Map) {
    for (final key in const ['modelTokenUsage', 'model_token_usage']) {
      mergeAgentUsageModelValues(values, source[key]);
    }
    if (values.isNotEmpty) {
      return values;
    }
    for (final key in const [
      'modelUsage',
      'model_usage',
      'models',
      'modelBreakdown',
      'model_breakdown',
      'byModel',
      'by_model',
    ]) {
      mergeAgentUsageModelValues(values, source[key]);
    }
    if (agentUsageModelName(source).isNotEmpty) {
      mergeAgentUsageModelValues(values, source);
    }
    return values;
  }
  mergeAgentUsageModelValues(values, source);
  return values;
}

void mergeAgentUsageModelValues(
  Map<String, AgentUsageModelTokens> values,
  Object? source,
) {
  if (source == null) {
    return;
  }
  if (source is List) {
    for (final item in source) {
      mergeAgentUsageModelValues(values, item);
    }
    return;
  }
  if (source is Map) {
    final modelName = agentUsageModelName(source);
    if (modelName.isNotEmpty) {
      final tokens = agentUsageTokensFromSource(source);
      if (tokens > 0) {
        final usage = AgentUsageModelTokens(
          totalTokens: tokens,
          breakdown: agentUsageTokenBreakdown(source, totalTokens: tokens),
        );
        values.update(
          modelName,
          (value) => value.merge(usage),
          ifAbsent: () => usage,
        );
      }
      return;
    }
    for (final entry in source.entries) {
      final label = agentUsageModelLabel(entry.key);
      if (label.isEmpty) {
        continue;
      }
      final tokens = agentUsageTokensFromSource(entry.value);
      if (tokens > 0) {
        final usage = AgentUsageModelTokens(
          totalTokens: tokens,
          breakdown: agentUsageTokenBreakdown(entry.value, totalTokens: tokens),
        );
        values.update(
          label,
          (value) => value.merge(usage),
          ifAbsent: () => usage,
        );
      }
    }
  }
}

AgentUsageTokenBreakdown agentUsageTokenBreakdown(
  Object? source, {
  required double totalTokens,
}) {
  if (source is! Map) {
    return AgentUsageTokenBreakdown.unavailable(totalTokens: totalTokens);
  }
  var candidate = source;
  const promptKeys = [
    'promptTokens',
    'prompt_tokens',
    'inputTokens',
    'input_tokens',
  ];
  const cachedKeys = [
    'cachedInputTokens',
    'cached_input_tokens',
    'cacheReadInputTokens',
    'cache_read_input_tokens',
  ];
  const completionKeys = [
    'completionTokens',
    'completion_tokens',
    'outputTokens',
    'output_tokens',
  ];
  var hasPrompt = _usageMapHasAnyKey(candidate, promptKeys);
  var hasCached = _usageMapHasAnyKey(candidate, cachedKeys);
  var hasCompletion = _usageMapHasAnyKey(candidate, completionKeys);
  if (!hasPrompt && !hasCompletion) {
    for (final key in const [
      'usage',
      'tokenUsage',
      'token_usage',
      'responseUsage',
      'response_usage',
    ]) {
      final nested = candidate[key];
      if (nested is! Map) {
        continue;
      }
      final nestedHasPrompt = _usageMapHasAnyKey(nested, promptKeys);
      final nestedHasCompletion = _usageMapHasAnyKey(nested, completionKeys);
      if (nestedHasPrompt || nestedHasCompletion) {
        candidate = nested;
        hasPrompt = nestedHasPrompt;
        hasCached = _usageMapHasAnyKey(nested, cachedKeys);
        hasCompletion = nestedHasCompletion;
        break;
      }
    }
  }
  final prompt = _firstUsageToken(candidate, promptKeys);
  final cached = _firstUsageToken(candidate, cachedKeys);
  final completion = _firstUsageToken(candidate, completionKeys);
  final componentTotal = prompt + completion;
  final normalizedTotal = totalTokens > 0 ? totalTokens : componentTotal;
  final totalMatches = normalizedTotal <= 0
      ? componentTotal <= 0
      : (componentTotal - normalizedTotal).abs() <= 0.5;
  final exact =
      hasPrompt &&
      hasCompletion &&
      componentTotal > 0 &&
      totalMatches &&
      cached >= 0 &&
      cached <= prompt + 0.5 &&
      (!hasCached || cached >= 0);
  return AgentUsageTokenBreakdown(
    promptTokens: prompt,
    cachedInputTokens: hasCached ? cached : 0,
    completionTokens: completion,
    totalTokens: normalizedTotal,
    isExact: exact,
  );
}

bool _usageMapHasAnyKey(Map<dynamic, dynamic> source, List<String> keys) {
  return keys.any(source.containsKey);
}

double _firstUsageToken(Map<dynamic, dynamic> source, List<String> keys) {
  for (final key in keys) {
    if (!source.containsKey(key)) {
      continue;
    }
    final value = agentUsageTokensFromSource(source[key]);
    if (value >= 0) {
      return value;
    }
  }
  return 0;
}
