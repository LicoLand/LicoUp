import 'package:flutter/material.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

import 'agent_usage_timeline_models.dart';

/// Explicit assignments are permanent, so insertion and usage rank do not
/// recolor existing Agents. Brand hues use muted, opaque chart tones so large
/// stacked fills remain comfortable beside the neutral application surfaces.
const _agentColors = <String, Color>{
  'antigravity': Color(0xFF8295CD),
  'kimi': Color(0xFF6FA3CA),
  'kimicode': Color(0xFF6FA3CA),
  'githubcopilot': Color(0xFFA38BCB),
  'copilot': Color(0xFFA38BCB),
  'kilocode': Color(0xFFCDC77B),
  'claudecode': Color(0xFFCD917A),
  'codex': Color(0xFF76AD9C),
  'cursor': Color(0xFFBD88A7),
  'hermesagent': Color(0xFFC48172),
  'hermes': Color(0xFFC48172),
  'openclaw': Color(0xFFCD7F87),
  'opencode': Color(0xFF79ADAF),
  'piagent': Color(0xFFBB9F72),
  'pi': Color(0xFFBB9F72),
  'deepseekharness': Color(0xFF878FD0),
};

const _additionalColors = [
  Color(0xFFC58F9D),
  Color(0xFF93AA87),
  Color(0xFFBAA077),
  Color(0xFF9C92BF),
  Color(0xFF7AA7B5),
  Color(0xFFB58DB0),
];

Color agentUsageSeriesColor(
  LicoThemeColors colors,
  String label, {
  AgentUsageChartGrouping grouping = AgentUsageChartGrouping.agent,
  String? displayName,
}) {
  final key = label.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');
  if (key.isEmpty) return colors.primaryStrong;
  if (key == 'others') return colors.textSecondary;
  final dark = colors.isDark;
  if (grouping != AgentUsageChartGrouping.model) {
    final base = _agentColors[key] ?? _additionalColors[_stableIndex(key)];
    return dark ? base : Color.lerp(base, Colors.black, 0.28)!;
  }
  final lower = (displayName ?? label).toLowerCase();
  final base = switch (lower) {
    _ when lower.startsWith('claude') => _agentColors['claudecode']!,
    _ when lower.startsWith('gpt') || RegExp(r'^o[134]\b').hasMatch(lower) =>
      _agentColors['codex']!,
    _ when lower.startsWith('gemini') => const Color(0xFF7A9EC8),
    _ when lower.startsWith('kimi') => _agentColors['kimi']!,
    _ when lower.startsWith('deepseek') => _agentColors['deepseekharness']!,
    _ when lower.startsWith('grok') => const Color(0xFFA594BE),
    _ when lower.startsWith('composer') => _agentColors['cursor']!,
    _ when lower.startsWith('glm') => _agentColors['opencode']!,
    _ when lower.startsWith('qwen') => const Color(0xFF9991BF),
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
    dark
        ? Color.lerp(base, Colors.white, 0.36)
        : Color.lerp(base, Colors.black, 0.28),
    Color.lerp(base, Colors.black, dark ? 0.20 : 0.50),
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
