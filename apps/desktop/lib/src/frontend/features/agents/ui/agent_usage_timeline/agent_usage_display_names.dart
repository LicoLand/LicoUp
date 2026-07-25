import 'package:licoup/src/application/features/agents/agent_product_names.dart';
import 'package:licoup/src/contracts/agent_usage_models.dart';

import 'agent_usage_source_parser.dart';

String agentUsageAgentDisplayName(AgentUsageAgentSummary agent) {
  final known = agentProductDisplayName(agent.agentId);
  if (known != null) {
    return known;
  }
  final fallback = agent.label.trim().isEmpty
      ? agent.agentId.trim()
      : agent.label.trim();
  final productLabel = fallback.replaceFirst(
    RegExp(r'\s*-\s*(?:desktop|cli|ide|plugin)\s*$', caseSensitive: false),
    '',
  );
  return agentUsageTitleCase(productLabel.replaceAll(RegExp(r'[-_]+'), ' '));
}

String agentUsageModelName(Map<dynamic, dynamic> source) {
  for (final key in const [
    'model',
    'modelId',
    'model_id',
    'modelName',
    'model_name',
    'name',
    'label',
    'displayName',
    'display_name',
    'title',
    'id',
  ]) {
    final value = agentUsageModelLabel(source[key]);
    if (value.isNotEmpty) {
      return value;
    }
  }
  return '';
}

String agentUsageModelLabel(Object? value) {
  if (value == null) {
    return '';
  }
  if (value is Map) {
    return agentUsageModelName(value);
  }
  if (value is List) {
    for (final item in value) {
      final nested = agentUsageModelLabel(item);
      if (nested.isNotEmpty) {
        return nested;
      }
    }
    return '';
  }
  final text = value.toString().trim();
  if (text.isEmpty) {
    return '';
  }
  final parsed = agentUsageJsonObjectFromText(text);
  if (parsed != null) {
    final nested = agentUsageModelName(parsed);
    if (nested.isNotEmpty) {
      return nested;
    }
  }
  return agentUsageModelDisplayName(agentUsagePlainModelName(text));
}

String agentUsagePlainModelName(String value) {
  var text = value.trim();
  while (text.startsWith('~')) {
    text = text.substring(1).trimLeft();
  }
  if (text.contains('/')) {
    final parts = text.split('/');
    final last = parts.last.trim();
    if (last.isNotEmpty) {
      text = last;
    }
  }
  return text;
}

String agentUsageModelDisplayName(String value) {
  final plain = agentUsagePlainModelName(value);
  if (plain.isEmpty) {
    return '';
  }
  final lower = plain.toLowerCase();
  final knownName = switch (lower) {
    'cursor-auto' || 'default' => 'Cursor Auto',
    'composer-2.5-fast' ||
    'composer-2-5-fast' ||
    'composer-2.5' ||
    'composer-2-5' => 'Composer 2.5',
    'others' => 'Others',
    _ => null,
  };
  if (knownName != null) {
    return knownName;
  }
  final words = plain
      .replaceAll(RegExp(r'[-_]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim()
      .split(' ');
  var text = words.map(_agentUsageModelWord).join(' ');
  // Version fragments arrive as separate words (claude-opus-4-6), so rejoin
  // adjacent numeric groups into dotted versions (Claude Opus 4.6).
  while (RegExp(r'\d \d').hasMatch(text)) {
    text = text.replaceAllMapped(
      RegExp(r'(\d) (\d)'),
      (match) => '${match[1]}.${match[2]}',
    );
  }
  return text;
}

String _agentUsageModelWord(String word) {
  final lower = word.toLowerCase();
  final known = switch (lower) {
    'api' => 'API',
    'cli' => 'CLI',
    'glm' => 'GLM',
    'gpt' => 'GPT',
    'ide' => 'IDE',
    'llm' => 'LLM',
    'mcp' => 'MCP',
    'ai' => 'AI',
    'deepseek' => 'DeepSeek',
    'chatgpt' => 'ChatGPT',
    _ => null,
  };
  if (known != null) {
    return known;
  }
  final version = RegExp(
    r'^([vr])([0-9].*)$',
    caseSensitive: false,
  ).firstMatch(word);
  if (version != null) {
    return '${version.group(1)!.toUpperCase()}${version.group(2)}';
  }
  final brandedVersion = RegExp(
    r'^(gpt|glm)([0-9].*)$',
    caseSensitive: false,
  ).firstMatch(word);
  if (brandedVersion != null) {
    return '${brandedVersion.group(1)!.toUpperCase()}${brandedVersion.group(2)}';
  }
  if (RegExp(r'^[0-9]+(?:\.[0-9]+)*$').hasMatch(word)) {
    return word;
  }
  return agentUsageTitleCase(word);
}

String agentUsageTitleCase(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) {
    return '';
  }
  return '${trimmed[0].toUpperCase()}${trimmed.substring(1).toLowerCase()}';
}
