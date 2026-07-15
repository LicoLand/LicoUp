import 'dart:math' as math;

/// Billable token classes retained by the local usage report.
///
/// [promptTokens] includes cached input tokens. The estimator subtracts the
/// cached subset before applying the regular input rate.
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

  double get billableCachedInputTokens =>
      math.min(math.max(0, cachedInputTokens), math.max(0, promptTokens));

  double get billableUncachedInputTokens =>
      math.max(0, promptTokens - billableCachedInputTokens);

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

class AgentUsageApiRate {
  const AgentUsageApiRate({
    required this.modelId,
    required this.inputUsdPerMillion,
    required this.cachedInputUsdPerMillion,
    required this.outputUsdPerMillion,
    required this.sourceUrl,
    required this.verifiedOn,
  });

  final String modelId;
  final double inputUsdPerMillion;
  final double cachedInputUsdPerMillion;
  final double outputUsdPerMillion;
  final String sourceUrl;
  final String verifiedOn;
}

class AgentUsageApiPriceEstimate {
  const AgentUsageApiPriceEstimate.available(double value)
    : assert(value >= 0),
      usd = value;

  const AgentUsageApiPriceEstimate.unavailable() : usd = null;

  final double? usd;

  bool get isAvailable => usd != null;
}

/// Standard pay-as-you-go text-token prices in USD per one million tokens.
///
/// Keep subscription quota products and unpriced research previews unavailable.
/// Prefer vendor list prices; cache-hit rates use published cache discounts when
/// the provider documents them, otherwise fall back to 10% of input.
class AgentUsageApiPricing {
  const AgentUsageApiPricing._();

  static const rates = <String, AgentUsageApiRate>{
    // OpenAI
    'gpt-5.5': AgentUsageApiRate(
      modelId: 'gpt-5.5',
      inputUsdPerMillion: 5,
      cachedInputUsdPerMillion: 0.5,
      outputUsdPerMillion: 30,
      sourceUrl: 'https://developers.openai.com/api/docs/models/gpt-5.5',
      verifiedOn: '2026-07-10',
    ),
    'gpt-5.6-sol': AgentUsageApiRate(
      modelId: 'gpt-5.6-sol',
      inputUsdPerMillion: 5,
      cachedInputUsdPerMillion: 0.5,
      outputUsdPerMillion: 30,
      sourceUrl: 'https://openai.com/index/previewing-gpt-5-6-sol/',
      verifiedOn: '2026-07-10',
    ),
    'gpt-5.4': AgentUsageApiRate(
      modelId: 'gpt-5.4',
      inputUsdPerMillion: 2.5,
      cachedInputUsdPerMillion: 0.25,
      outputUsdPerMillion: 15,
      sourceUrl: 'https://developers.openai.com/api/docs/models/gpt-5.4',
      verifiedOn: '2026-07-10',
    ),
    'gpt-5.4-mini': AgentUsageApiRate(
      modelId: 'gpt-5.4-mini',
      inputUsdPerMillion: 0.75,
      cachedInputUsdPerMillion: 0.075,
      outputUsdPerMillion: 4.5,
      sourceUrl: 'https://developers.openai.com/api/docs/models/gpt-5.4-mini',
      verifiedOn: '2026-07-10',
    ),
    'gpt-5.3-codex': AgentUsageApiRate(
      modelId: 'gpt-5.3-codex',
      inputUsdPerMillion: 1.75,
      cachedInputUsdPerMillion: 0.175,
      outputUsdPerMillion: 14,
      sourceUrl: 'https://developers.openai.com/api/docs/models',
      verifiedOn: '2026-07-10',
    ),
    // Anthropic Claude
    'claude-opus-4.6': AgentUsageApiRate(
      modelId: 'claude-opus-4.6',
      inputUsdPerMillion: 5,
      cachedInputUsdPerMillion: 0.5,
      outputUsdPerMillion: 25,
      sourceUrl: 'https://platform.claude.com/docs/en/about-claude/pricing',
      verifiedOn: '2026-07-11',
    ),
    'claude-opus-4.7': AgentUsageApiRate(
      modelId: 'claude-opus-4.7',
      inputUsdPerMillion: 5,
      cachedInputUsdPerMillion: 0.5,
      outputUsdPerMillion: 25,
      sourceUrl: 'https://platform.claude.com/docs/en/about-claude/pricing',
      verifiedOn: '2026-07-11',
    ),
    'claude-opus-4.8': AgentUsageApiRate(
      modelId: 'claude-opus-4.8',
      inputUsdPerMillion: 5,
      cachedInputUsdPerMillion: 0.5,
      outputUsdPerMillion: 25,
      sourceUrl: 'https://platform.claude.com/docs/en/about-claude/pricing',
      verifiedOn: '2026-07-11',
    ),
    'claude-opus-latest': AgentUsageApiRate(
      modelId: 'claude-opus-latest',
      inputUsdPerMillion: 5,
      cachedInputUsdPerMillion: 0.5,
      outputUsdPerMillion: 25,
      sourceUrl: 'https://platform.claude.com/docs/en/about-claude/pricing',
      verifiedOn: '2026-07-11',
    ),
    'claude-sonnet-4': AgentUsageApiRate(
      modelId: 'claude-sonnet-4',
      inputUsdPerMillion: 3,
      cachedInputUsdPerMillion: 0.3,
      outputUsdPerMillion: 15,
      sourceUrl: 'https://platform.claude.com/docs/en/about-claude/pricing',
      verifiedOn: '2026-07-11',
    ),
    'claude-sonnet-4.5': AgentUsageApiRate(
      modelId: 'claude-sonnet-4.5',
      inputUsdPerMillion: 3,
      cachedInputUsdPerMillion: 0.3,
      outputUsdPerMillion: 15,
      sourceUrl: 'https://platform.claude.com/docs/en/about-claude/pricing',
      verifiedOn: '2026-07-11',
    ),
    'claude-sonnet-4.6': AgentUsageApiRate(
      modelId: 'claude-sonnet-4.6',
      inputUsdPerMillion: 3,
      cachedInputUsdPerMillion: 0.3,
      outputUsdPerMillion: 15,
      sourceUrl: 'https://platform.claude.com/docs/en/about-claude/pricing',
      verifiedOn: '2026-07-11',
    ),
    'claude-sonnet-5': AgentUsageApiRate(
      modelId: 'claude-sonnet-5',
      inputUsdPerMillion: 2,
      cachedInputUsdPerMillion: 0.2,
      outputUsdPerMillion: 10,
      sourceUrl: 'https://platform.claude.com/docs/en/about-claude/pricing',
      verifiedOn: '2026-07-11',
    ),
    'claude-haiku-4.5': AgentUsageApiRate(
      modelId: 'claude-haiku-4.5',
      inputUsdPerMillion: 1,
      cachedInputUsdPerMillion: 0.1,
      outputUsdPerMillion: 5,
      sourceUrl: 'https://platform.claude.com/docs/en/about-claude/pricing',
      verifiedOn: '2026-07-11',
    ),
    'claude-haiku': AgentUsageApiRate(
      modelId: 'claude-haiku',
      inputUsdPerMillion: 1,
      cachedInputUsdPerMillion: 0.1,
      outputUsdPerMillion: 5,
      sourceUrl: 'https://platform.claude.com/docs/en/about-claude/pricing',
      verifiedOn: '2026-07-11',
    ),
    // DeepSeek
    'deepseek-v4-flash': AgentUsageApiRate(
      modelId: 'deepseek-v4-flash',
      inputUsdPerMillion: 0.14,
      cachedInputUsdPerMillion: 0.0028,
      outputUsdPerMillion: 0.28,
      sourceUrl: 'https://api-docs.deepseek.com/quick_start/pricing',
      verifiedOn: '2026-07-10',
    ),
    'deepseek-v4-pro': AgentUsageApiRate(
      modelId: 'deepseek-v4-pro',
      inputUsdPerMillion: 0.435,
      cachedInputUsdPerMillion: 0.003625,
      outputUsdPerMillion: 0.87,
      sourceUrl: 'https://api-docs.deepseek.com/quick_start/pricing',
      verifiedOn: '2026-07-10',
    ),
    // Moonshot / Kimi (international USD list)
    'kimi-k2.6': AgentUsageApiRate(
      modelId: 'kimi-k2.6',
      inputUsdPerMillion: 0.95,
      cachedInputUsdPerMillion: 0.16,
      outputUsdPerMillion: 4,
      sourceUrl: 'https://platform.moonshot.cn/docs/pricing',
      verifiedOn: '2026-07-11',
    ),
    'kimi-k2.5': AgentUsageApiRate(
      modelId: 'kimi-k2.5',
      inputUsdPerMillion: 0.6,
      cachedInputUsdPerMillion: 0.1,
      outputUsdPerMillion: 3,
      sourceUrl: 'https://platform.moonshot.cn/docs/pricing',
      verifiedOn: '2026-07-11',
    ),
    'kimi-k2': AgentUsageApiRate(
      modelId: 'kimi-k2',
      inputUsdPerMillion: 0.6,
      cachedInputUsdPerMillion: 0.15,
      outputUsdPerMillion: 2.5,
      sourceUrl: 'https://platform.moonshot.cn/docs/pricing',
      verifiedOn: '2026-07-11',
    ),
    // Cursor Auto / Composer routed models
    'cursor-auto': AgentUsageApiRate(
      modelId: 'cursor-auto',
      inputUsdPerMillion: 1.25,
      cachedInputUsdPerMillion: 0.25,
      outputUsdPerMillion: 6,
      sourceUrl: 'https://cursor.com/docs',
      verifiedOn: '2026-07-12',
    ),
    'composer-2.5-fast': AgentUsageApiRate(
      modelId: 'composer-2.5-fast',
      inputUsdPerMillion: 1.25,
      cachedInputUsdPerMillion: 0.25,
      outputUsdPerMillion: 6,
      sourceUrl: 'https://cursor.com/docs',
      verifiedOn: '2026-07-12',
    ),
    // Google Gemini
    'gemini-2.5-pro': AgentUsageApiRate(
      modelId: 'gemini-2.5-pro',
      inputUsdPerMillion: 1.25,
      cachedInputUsdPerMillion: 0.125,
      outputUsdPerMillion: 10,
      sourceUrl: 'https://ai.google.dev/pricing',
      verifiedOn: '2026-07-11',
    ),
    'gemini-2.5-flash': AgentUsageApiRate(
      modelId: 'gemini-2.5-flash',
      inputUsdPerMillion: 0.3,
      cachedInputUsdPerMillion: 0.03,
      outputUsdPerMillion: 2.5,
      sourceUrl: 'https://ai.google.dev/pricing',
      verifiedOn: '2026-07-11',
    ),
    'gemini-2.5-flash-lite': AgentUsageApiRate(
      modelId: 'gemini-2.5-flash-lite',
      inputUsdPerMillion: 0.1,
      cachedInputUsdPerMillion: 0.01,
      outputUsdPerMillion: 0.4,
      sourceUrl: 'https://ai.google.dev/pricing',
      verifiedOn: '2026-07-11',
    ),
    'gemini-3-flash': AgentUsageApiRate(
      modelId: 'gemini-3-flash',
      inputUsdPerMillion: 0.5,
      cachedInputUsdPerMillion: 0.05,
      outputUsdPerMillion: 3,
      sourceUrl: 'https://ai.google.dev/pricing',
      verifiedOn: '2026-07-11',
    ),
    'gemini-3.1-pro': AgentUsageApiRate(
      modelId: 'gemini-3.1-pro',
      inputUsdPerMillion: 2,
      cachedInputUsdPerMillion: 0.2,
      outputUsdPerMillion: 12,
      sourceUrl: 'https://ai.google.dev/pricing',
      verifiedOn: '2026-07-11',
    ),
  };

  static AgentUsageApiRate? rateFor(String model) {
    final normalized = normalizeModelKey(model);
    final canonical = _canonicalizeModelKey(normalized);
    final direct = rates[canonical];
    if (direct != null) {
      return direct;
    }
    final withoutSnapshot = canonical.replaceFirst(
      RegExp(r'-\d{4}-\d{2}-\d{2}$'),
      '',
    );
    return rates[_canonicalizeModelKey(withoutSnapshot)];
  }

  static AgentUsageApiPriceEstimate estimate({
    required String model,
    required AgentUsageTokenBreakdown usage,
  }) {
    final rate = rateFor(model);
    if (rate == null || usage.totalTokens <= 0) {
      return const AgentUsageApiPriceEstimate.unavailable();
    }
    if (usage.isExact) {
      final usd =
          (usage.billableUncachedInputTokens * rate.inputUsdPerMillion +
              usage.billableCachedInputTokens * rate.cachedInputUsdPerMillion +
              math.max(0, usage.completionTokens) * rate.outputUsdPerMillion) /
          1000000;
      return AgentUsageApiPriceEstimate.available(usd);
    }
    // Total-only agent reports are common. Approximate with a fixed chat blend
    // so the monitoring board can still surface a directional API cost.
    const inputShare = 0.75;
    const outputShare = 0.25;
    final usd =
        (usage.totalTokens * inputShare * rate.inputUsdPerMillion +
            usage.totalTokens * outputShare * rate.outputUsdPerMillion) /
        1000000;
    return AgentUsageApiPriceEstimate.available(usd);
  }

  static String normalizeModelKey(String value) {
    var normalized = value.trim().toLowerCase();
    while (normalized.startsWith('~')) {
      normalized = normalized.substring(1).trimLeft();
    }
    if (normalized.contains('/')) {
      normalized = normalized.split('/').last.trim();
    }
    return normalized
        .replaceAll(RegExp(r'[_\s]+'), '-')
        .replaceAll(RegExp(r'-+'), '-')
        .replaceAll(RegExp(r'^-|-$'), '');
  }

  static String _canonicalizeModelKey(String normalized) {
    return switch (normalized) {
      'default' || 'cursor-default' || 'auto' => 'cursor-auto',
      'composer-2-5-fast' || 'composer-2.5' => 'composer-2.5-fast',
      'claude-opus-4-6' => 'claude-opus-4.6',
      'claude-opus-4-7' => 'claude-opus-4.7',
      'claude-opus-4-8' => 'claude-opus-4.8',
      'claude-sonnet-4-5' => 'claude-sonnet-4.5',
      'claude-sonnet-4-6' => 'claude-sonnet-4.6',
      'claude-haiku-4-5' => 'claude-haiku-4.5',
      'kimi-k2-6' || 'kimi-k2.6' || 'moonshot-kimi-k2.6' => 'kimi-k2.6',
      'kimi-k2-5' || 'kimi-k2.5' || 'moonshot-kimi-k2.5' => 'kimi-k2.5',
      'kimi-k2-0711' || 'kimi-k2-0905' => 'kimi-k2',
      'gemini-2-5-pro' => 'gemini-2.5-pro',
      'gemini-2-5-flash' => 'gemini-2.5-flash',
      'gemini-2-5-flash-lite' => 'gemini-2.5-flash-lite',
      'gemini-3-1-pro' || 'gemini-3.1-pro-preview' => 'gemini-3.1-pro',
      'gemini-3-flash-preview' => 'gemini-3-flash',
      _ => normalized,
    };
  }
}
