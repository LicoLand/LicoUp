import 'package:licoup/src/contracts/agent_tool_allowlist_repository.dart';
import 'package:licoup/src/platform/mobile_relay/mobile_relay_json_store.dart';

/// Persists per-agent tool allowlists ("allow and remember").
final class AgentToolAllowlistStore implements AgentToolAllowlistRepository {
  const AgentToolAllowlistStore({
    MobileRelayJsonStore jsonStore = const MobileRelayJsonStore(),
  }) : _jsonStore = jsonStore;

  static const _fileName = 'agent-tool-allowlists.json';
  static const _schemaVersion = 1;
  static const _maxAgents = 64;
  static const _maxToolsPerAgent = 64;

  final MobileRelayJsonStore _jsonStore;

  @override
  Future<Map<String, List<String>>> load(Object portableData) async {
    final decoded = await _jsonStore.read(portableData, _fileName);
    if (decoded is! Map || decoded['schemaVersion'] != _schemaVersion) {
      return const {};
    }
    final raw = decoded['allowlistsByAgent'];
    if (raw is! Map) return const {};

    final restored = <String, List<String>>{};
    for (final entry in raw.entries.take(_maxAgents)) {
      final agentId = entry.key.toString().trim();
      if (agentId.isEmpty || agentId.length > 128 || entry.value is! List) {
        continue;
      }
      final tools = <String>[];
      for (final item in (entry.value as List).take(_maxToolsPerAgent)) {
        final tool = item.toString().trim();
        if (tool.isNotEmpty && tool.length <= 128 && !tools.contains(tool)) {
          tools.add(tool);
        }
      }
      if (tools.isNotEmpty) {
        restored[agentId] = List.unmodifiable(tools);
      }
    }
    return Map.unmodifiable(restored);
  }

  @override
  Future<void> save(
    Object portableData,
    Map<String, List<String>> allowlistsByAgent,
  ) async {
    final trimmed = <String, List<String>>{};
    for (final entry in allowlistsByAgent.entries.take(_maxAgents)) {
      final agentId = entry.key.trim();
      if (agentId.isEmpty || agentId.length > 128) continue;
      final tools = <String>[];
      for (final tool in entry.value.take(_maxToolsPerAgent)) {
        final normalized = tool.trim();
        if (normalized.isNotEmpty &&
            normalized.length <= 128 &&
            !tools.contains(normalized)) {
          tools.add(normalized);
        }
      }
      if (tools.isNotEmpty) {
        trimmed[agentId] = List.unmodifiable(tools);
      }
    }
    await _jsonStore.write(portableData, _fileName, {
      'schemaVersion': _schemaVersion,
      'allowlistsByAgent': trimmed,
    });
  }
}
