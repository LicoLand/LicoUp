import 'package:flutter/material.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';

Color agentUsageSeriesColor(LicoThemeColors colors, String label) {
  final key = _usageColorKey(label);
  if (key.isEmpty) {
    return colors.primaryStrong;
  }
  final known = switch (key) {
    'codex' || 'chatgptdesktop' => const Color(0xFF38BDF8),
    'claude' || 'claudecode' || 'claudecodecli' => const Color(0xFFF59E0B),
    'opencode' || 'opencodecli' => const Color(0xFF22C55E),
    'kilocode' || 'kilocodecli' || 'kilo' => const Color(0xFFA78BFA),
    'antigravity' || 'antigravityide' => const Color(0xFFF472B6),
    'githubcopilot' ||
    'githubcopilotplugin' ||
    'copilot' => const Color(0xFF06B6D4),
    'cursor' || 'cursoride' => const Color(0xFFF97316),
    'kimicodecli' => const Color(0xFF84CC16),
    'kimidesktop' => const Color(0xFF60A5FA),
    'vscode' || 'visualstudiocode' => const Color(0xFF3B82F6),
    _ => null,
  };
  if (known != null) {
    return known;
  }
  const palette = [
    Color(0xFF38BDF8),
    Color(0xFFF59E0B),
    Color(0xFF22C55E),
    Color(0xFF8B5CF6),
    Color(0xFF06B6D4),
    Color(0xFFF97316),
    Color(0xFFEC4899),
    Color(0xFF84CC16),
    Color(0xFF60A5FA),
    Color(0xFFF43F5E),
  ];
  return palette[_stableUsageColorIndex(key, palette.length)];
}

String _usageColorKey(String label) {
  return label.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '').trim();
}

int _stableUsageColorIndex(String key, int paletteLength) {
  var hash = 0;
  for (final codeUnit in key.codeUnits) {
    hash = 0x1fffffff & (hash + codeUnit);
    hash = 0x1fffffff & (hash + ((0x0007ffff & hash) << 10));
    hash ^= hash >> 6;
  }
  hash = 0x1fffffff & (hash + ((0x03ffffff & hash) << 3));
  hash ^= hash >> 11;
  hash = 0x1fffffff & (hash + ((0x00003fff & hash) << 15));
  return hash.abs() % paletteLength;
}
