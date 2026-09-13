import 'package:licoup/src/contracts/agent_usage_models.dart';

import 'agent_usage_source_parser.dart';

class AgentUsageModelTokens {
  const AgentUsageModelTokens({
    required this.totalTokens,
    required this.breakdown,
    this.requestCount = 0,
    this.tokenUnavailableRequests = 0,
    this.variants = const {},
    this.canonicalId = '',
    this.displayName = '',
    this.unattributedVariantUsage,
  });

  final double totalTokens;
  final AgentUsageTokenBreakdown breakdown;

  /// Event-level requests the source attributed to this model. Hosted ledgers
  /// report requests whose payload carried no token fields; those never become
  /// a token total, they stay a request count.
  final int requestCount;

  /// Requests counted here that carried no token fields at all.
  final int tokenUnavailableRequests;
  final Map<String, AgentUsageModelVariant> variants;
  final String canonicalId;
  final String displayName;
  final AgentUsageModelVariant? unattributedVariantUsage;

  AgentUsageModelTokens merge(AgentUsageModelTokens other) {
    return AgentUsageModelTokens(
      totalTokens: totalTokens + other.totalTokens,
      breakdown: breakdown.merge(other.breakdown),
      requestCount: requestCount + other.requestCount,
      tokenUnavailableRequests:
          tokenUnavailableRequests + other.tokenUnavailableRequests,
      canonicalId: canonicalId,
      displayName: displayName.isEmpty || displayName == canonicalId
          ? other.displayName
          : displayName,
      unattributedVariantUsage: unattributedVariantUsage == null
          ? other.unattributedVariantUsage
          : other.unattributedVariantUsage == null
          ? unattributedVariantUsage
          : unattributedVariantUsage!.merge(other.unattributedVariantUsage!),
      variants: {
        ...variants,
        for (final entry in other.variants.entries)
          entry.key: variants[entry.key]?.merge(entry.value) ?? entry.value,
      },
    );
  }

  AgentUsageModelTokens withBreakdown(AgentUsageTokenBreakdown value) {
    return AgentUsageModelTokens(
      totalTokens: totalTokens,
      breakdown: value,
      requestCount: requestCount,
      tokenUnavailableRequests: tokenUnavailableRequests,
      variants: variants,
      canonicalId: canonicalId,
      displayName: displayName,
      unattributedVariantUsage: unattributedVariantUsage,
    );
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

/// Reads model IDs and display facts from the native usage projection. Older
/// retained numeric model maps remain readable without interpreting their IDs.
Map<String, AgentUsageModelTokens> agentUsageModelUsageMap(Object? source) {
  if (source is! Map) {
    return const {};
  }
  final models = source['modelTokenUsage'] ?? source['modelUsage'];
  if (models is! Map) {
    return const {};
  }
  return {
    for (final entry in models.entries)
      if (entry.key is String && (entry.key as String).isNotEmpty)
        entry.key as String: _nativeModelUsage(
          entry.key as String,
          entry.value,
        ),
  };
}

AgentUsageModelTokens _nativeModelUsage(String canonicalId, Object? source) {
  final native = AgentUsageModelUsage.fromJson(canonicalId, source);
  final total = source is num
      ? source.toDouble()
      : native.totals.totalTokens.toDouble();
  return AgentUsageModelTokens(
    canonicalId: native.canonicalId,
    displayName: native.displayName,
    totalTokens: total,
    breakdown: agentUsageTokenBreakdown(source, totalTokens: total),
    requestCount: native.totals.requestCount,
    tokenUnavailableRequests: native.totals.tokenUnavailableRequests,
    variants: native.variants,
    unattributedVariantUsage: native.unattributedVariantUsage,
  );
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
