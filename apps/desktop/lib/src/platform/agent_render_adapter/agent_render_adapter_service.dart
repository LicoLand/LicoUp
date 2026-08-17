import 'dart:convert';
import 'dart:io' show Directory, File, Platform;

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'package:licoup/src/contracts/agent_render_adapter_source.dart';

class DefaultAgentRenderAdapterJsonSource
    implements AgentRenderAdapterJsonSource {
  DefaultAgentRenderAdapterJsonSource({
    AssetBundle? assetBundle,
    Map<String, String>? environmentOverride,
  }) : _assetBundle = assetBundle ?? rootBundle,
       _environmentOverride = environmentOverride;

  static const String externalRootsEnvironmentKey =
      'LICOUP_AGENT_RENDER_ADAPTER_ROOTS';

  final AssetBundle _assetBundle;
  final Map<String, String>? _environmentOverride;

  @override
  Future<List<Map<String, dynamic>>> loadAdapterJson() async {
    return [...await _loadAssetAdapters(), ...await _loadExternalAdapters()];
  }

  Future<List<Map<String, dynamic>>> _loadAssetAdapters() async {
    try {
      final indexRaw = await _assetBundle.loadString(
        'assets/agent-render-adapters/index.json',
      );
      final index = jsonDecode(indexRaw);
      final adapterFiles = _rawStringList(_map(index)['adapters']);
      final adapters = <Map<String, dynamic>>[];
      for (final file in adapterFiles) {
        final raw = await _assetBundle.loadString(
          'assets/agent-render-adapters/$file',
        );
        final parsed = jsonDecode(raw);
        if (parsed is Map<String, dynamic>) {
          adapters.add(parsed);
        }
      }
      return adapters;
    } catch (_) {
      return const [];
    }
  }

  Future<List<Map<String, dynamic>>> _loadExternalAdapters() async {
    final roots = <Directory>[];
    final configured = _environment[externalRootsEnvironmentKey];
    if (configured != null && configured.trim().isNotEmpty) {
      final separator = Platform.isWindows ? ';' : ':';
      roots.addAll(
        configured
            .split(separator)
            .map((path) => path.trim())
            .where((path) => path.isNotEmpty)
            .map(Directory.new),
      );
    }
    final home = (_environment['HOME'] ?? _environment['USERPROFILE'] ?? '')
        .trim();
    if (home.isNotEmpty) {
      roots.add(Directory(p.join(home, '.lico-up', 'agent-render-adapters')));
    }

    final adapters = <Map<String, dynamic>>[];
    for (final root in roots) {
      adapters.addAll(await _loadExternalRoot(root));
    }
    return adapters;
  }

  Future<List<Map<String, dynamic>>> _loadExternalRoot(Directory root) async {
    if (!await root.exists()) {
      return const [];
    }
    final files = <File>[];
    final index = File(p.join(root.path, 'index.json'));
    if (await index.exists()) {
      try {
        final parsed = jsonDecode(await index.readAsString());
        for (final item in _rawStringList(_map(parsed)['adapters'])) {
          files.add(File(p.join(root.path, item)));
        }
      } catch (_) {
        return const [];
      }
    } else {
      await for (final entry in root.list(followLinks: false)) {
        if (entry is File && entry.path.toLowerCase().endsWith('.json')) {
          files.add(entry);
        }
      }
    }

    final adapters = <Map<String, dynamic>>[];
    for (final file in files) {
      try {
        final parsed = jsonDecode(await file.readAsString());
        if (parsed is Map<String, dynamic>) {
          adapters.add(parsed);
        }
      } catch (_) {
        // A bad external profile should not break the conversation surface.
      }
    }
    return adapters;
  }

  Map<String, String> get _environment =>
      _environmentOverride ?? Platform.environment;
}

Map<String, dynamic> _map(Object? value) {
  return value is Map<String, dynamic> ? value : const {};
}

List<String> _rawStringList(Object? value) {
  if (value is! List) {
    return const [];
  }
  return value
      .whereType<String>()
      .map((item) => item.trim())
      .where((item) => item.isNotEmpty)
      .toList(growable: false);
}
