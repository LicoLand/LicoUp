import 'dart:convert';

class AgentUsageSourceDailyEntry {
  const AgentUsageSourceDailyEntry({required this.date, required this.source});

  final String date;
  final Object? source;
}

List<AgentUsageSourceDailyEntry> agentUsageDailySourceEntries(Object? source) {
  return mapAgentUsageDailySource(
    source,
    (date, value) => AgentUsageSourceDailyEntry(date: date, source: value),
  );
}

List<T> mapAgentUsageDailySource<T>(
  Object? source,
  T? Function(String date, Object? value) parse,
) {
  if (source == null) {
    return const [];
  }
  if (source is List) {
    return [
      for (final item in source) ...mapAgentUsageDailySource(item, parse),
    ];
  }
  if (source is Map) {
    final directDate = agentUsageSourceDateKey(
      source['date'] ??
          source['day'] ??
          source['bucket'] ??
          source['generatedAt'] ??
          source['time'] ??
          source['timestamp'],
    );
    if (directDate.isNotEmpty) {
      final direct = parse(directDate, source);
      if (direct != null) {
        return [direct];
      }
    }
    final entries = <T>[];
    for (final entry in source.entries) {
      final date = agentUsageSourceDateKey(entry.key);
      if (date.isEmpty) {
        continue;
      }
      final parsed = parse(date, entry.value);
      if (parsed != null) {
        entries.add(parsed);
      }
    }
    return entries;
  }
  return const [];
}

String agentUsageDateKey(DateTime value) {
  final day = DateTime(value.year, value.month, value.day);
  return '${day.year}-${_twoDigits(day.month)}-${_twoDigits(day.day)}';
}

String agentUsageSourceDateKey(Object? value) {
  if (value == null) {
    return '';
  }
  if (value is DateTime) {
    return agentUsageDateKey(value);
  }
  final text = value.toString().trim();
  if (text.isEmpty) {
    return '';
  }
  final parsed = DateTime.tryParse(text);
  if (parsed != null) {
    return agentUsageDateKey(parsed);
  }
  final dateMatch = RegExp(r'^\d{4}-\d{2}-\d{2}$').firstMatch(text);
  return dateMatch?.group(0) ?? '';
}

Map<dynamic, dynamic>? agentUsageJsonObjectFromText(String text) {
  final trimmed = text.trim();
  if (!trimmed.startsWith('{') || !trimmed.endsWith('}')) {
    return null;
  }
  try {
    final parsed = jsonDecode(trimmed);
    return parsed is Map ? parsed : null;
  } catch (_) {
    return null;
  }
}

double agentUsageTokensFromSource(Object? value) {
  if (value == null) {
    return 0;
  }
  if (value is int) {
    return value.toDouble();
  }
  if (value is num) {
    return value.toDouble();
  }
  final parsed = double.tryParse(value.toString().replaceAll(',', ''));
  if (parsed != null) {
    return parsed;
  }
  if (value is List) {
    var total = 0.0;
    for (final item in value) {
      total += agentUsageTokensFromSource(item);
    }
    return total;
  }
  if (value is Map) {
    for (final key in const [
      'totalTokens',
      'total_tokens',
      'tokens',
      'tokenCount',
      'token_count',
      'usageTokens',
      'usage_tokens',
    ]) {
      final tokens = agentUsageTokensFromSource(value[key]);
      if (tokens > 0) {
        return tokens;
      }
    }
    final prompt =
        agentUsageTokensFromSource(value['promptTokens']) +
        agentUsageTokensFromSource(value['prompt_tokens']) +
        agentUsageTokensFromSource(value['inputTokens']) +
        agentUsageTokensFromSource(value['input_tokens']);
    final completion =
        agentUsageTokensFromSource(value['completionTokens']) +
        agentUsageTokensFromSource(value['completion_tokens']) +
        agentUsageTokensFromSource(value['outputTokens']) +
        agentUsageTokensFromSource(value['output_tokens']);
    if (prompt + completion > 0) {
      return prompt + completion;
    }
    for (final key in const [
      'usage',
      'tokenUsage',
      'token_usage',
      'responseUsage',
      'response_usage',
    ]) {
      final tokens = agentUsageTokensFromSource(value[key]);
      if (tokens > 0) {
        return tokens;
      }
    }
  }
  return 0;
}

String _twoDigits(int value) => value.toString().padLeft(2, '0');
