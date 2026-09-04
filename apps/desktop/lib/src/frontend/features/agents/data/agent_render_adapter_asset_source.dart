import 'dart:convert';

import 'package:flutter/services.dart';

import 'package:licoup/src/contracts/agent_render_adapter_source.dart';

/// Decodes packaged render-adapter assets before they reach display widgets.
final class AssetAgentRenderAdapterJsonSource
    implements AgentRenderAdapterJsonSource {
  AssetAgentRenderAdapterJsonSource([AssetBundle? assetBundle])
    : _assetBundle = assetBundle ?? rootBundle;

  final AssetBundle _assetBundle;

  @override
  Future<List<Map<String, dynamic>>> loadAdapterJson() async {
    try {
      final indexRaw = await _assetBundle.loadString(
        'assets/agent-render-adapters/index.json',
      );
      final index = _decodeObject(indexRaw);
      final adapterFiles = _stringList(index['adapters']);
      final adapters = <Map<String, dynamic>>[];
      for (final file in adapterFiles) {
        final raw = await _assetBundle.loadString(
          'assets/agent-render-adapters/$file',
        );
        final parsed = _decodeObject(raw);
        if (parsed.isNotEmpty) adapters.add(parsed);
      }
      return List<Map<String, dynamic>>.unmodifiable(adapters);
    } on Object {
      return const <Map<String, dynamic>>[];
    }
  }
}

Map<String, dynamic> _decodeObject(String source) {
  final decoded = jsonDecode(source);
  return decoded is Map
      ? Map<String, dynamic>.from(decoded)
      : const <String, dynamic>{};
}

List<String> _stringList(Object? value) {
  if (value is! List) return const <String>[];
  return value
      .whereType<String>()
      .map((item) => item.trim().toLowerCase())
      .where((item) => item.isNotEmpty || item == '*')
      .toList(growable: false);
}
