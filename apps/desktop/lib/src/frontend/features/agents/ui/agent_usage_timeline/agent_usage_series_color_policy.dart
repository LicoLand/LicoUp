import 'package:flutter/material.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

import 'agent_usage_timeline_models.dart';

/// Explicit assignments are permanent, so insertion and usage rank do not
/// recolor existing Agents. Bundled brand accents are reused where available.
const _agentColors = <String, Color>{
  'antigravity': Color(0xFF5B7CFA),
  'kimi': Color(0xFF1783FF),
  'kimicode': Color(0xFF1783FF),
  'githubcopilot': Color(0xFF8C48FF),
  'copilot': Color(0xFF8C48FF),
  'kilocode': Color(0xFFF8F676),
  'claudecode': Color(0xFFD97757),
  'codex': Color(0xFF10A37F),
  'cursor': Color(0xFFDA5D9E),
  'hermesagent': Color(0xFFCC5C49),
  'hermes': Color(0xFFCC5C49),
  'openclaw': Color(0xFFEF5350),
  'opencode': Color(0xFF31B4B9),
  'piagent': Color(0xFFC59A54),
  'pi': Color(0xFFC59A54),
  'deepseekharness': Color(0xFF536AF1),
};

const _additionalColors = [
  Color(0xFFDC6A84),
  Color(0xFF5B9B5A),
  Color(0xFFBE8A43),
  Color(0xFF7E72C7),
  Color(0xFF399CAE),
  Color(0xFFC65BBA),
];

Color agentUsageSeriesColor(
  LicoThemeColors colors,
  String label, {
  AgentUsageChartGrouping grouping = AgentUsageChartGrouping.agent,
}) {
  final key = label.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');
  if (key.isEmpty) return colors.primaryStrong;
  if (key == 'others') return colors.textSecondary;
  if (grouping != AgentUsageChartGrouping.model) {
    return _agentColors[key] ?? _additionalColors[_stableIndex(key)];
  }
  final lower = label.toLowerCase();
  final base = switch (lower) {
    _ when lower.startsWith('claude') => const Color(0xFFD97757),
    _ when lower.startsWith('gpt') || RegExp(r'^o[134]\b').hasMatch(lower) =>
      const Color(0xFF10A37F),
    _ when lower.startsWith('gemini') => const Color(0xFF4285F4),
    _ when lower.startsWith('kimi') => const Color(0xFF1783FF),
    _ when lower.startsWith('deepseek') => const Color(0xFF536AF1),
    _ when lower.startsWith('grok') => const Color(0xFF9872C9),
    _ when lower.startsWith('composer') => const Color(0xFFDA5D9E),
    _ when lower.startsWith('glm') => const Color(0xFF48A6A7),
    _ when lower.startsWith('qwen') => const Color(0xFF7566C2),
    _ => _additionalColors[_stableIndex(key)],
  };
  final tier = switch (lower) {
    _
        when lower.contains('fable') ||
            lower.contains('astra') ||
            lower.contains('ultra') =>
      4,
    _
        when lower.contains('opus') ||
            lower.contains('sol') ||
            lower.contains('pro') ||
            lower.contains('large') =>
      3,
    _ when lower.contains('sonnet') || lower.contains('terra') => 2,
    _
        when lower.contains('haiku') ||
            lower.contains('luna') ||
            lower.contains('flash') ||
            lower.contains('mini') ||
            lower.contains('spark') ||
            lower.contains('lite') =>
      1,
    _ => 2,
  };
  final version = _versionStrength(lower);
  // Tier differences remain visible; numeric version components deepen their
  // own tier. Floating color channels retain even small version differences.
  final depth = ((tier - 1) * 0.22 + (version / 20).clamp(0.0, 0.34));
  return Color.lerp(
    Color.lerp(base, Colors.white, 0.58),
    Color.lerp(base, Colors.black, 0.36),
    depth,
  )!;
}

double _versionStrength(String label) {
  final match = RegExp(r'\d+(?:\.\d+)*').firstMatch(label);
  final parts =
      match?.group(0)?.split('.').map(int.parse).toList() ?? const <int>[];
  if (parts.isEmpty) return 0;
  var fraction = 0.0;
  for (var index = parts.length - 1; index > 0; index--) {
    final component = parts[index] + fraction;
    fraction = component / (component + 1);
  }
  return parts.first + fraction;
}

int _stableIndex(String key) {
  var hash = 0;
  for (final codeUnit in key.codeUnits) {
    hash = (hash * 31 + codeUnit) & 0x1fffffff;
  }
  return hash % _additionalColors.length;
}
