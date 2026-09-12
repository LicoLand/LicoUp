import 'package:flutter/material.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

Color agentUsageSeriesColor(LicoThemeColors colors, String label) {
  final key = _usageColorKey(label);
  if (key.isEmpty) {
    return colors.primaryStrong;
  }
  // Every series belongs to one silver-to-electric-yellow ramp. Labels keep
  // their stable position as data arrives; status colors are never chart data.
  final t = _stableUsageColorIndex(key, 9) / 8;
  final start = colors.isDark ? colors.textSecondary : colors.accent;
  final end = colors.isDark ? colors.primary : colors.primaryStrong;
  return Color.lerp(start, end, t)!;
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
