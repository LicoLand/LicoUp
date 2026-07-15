import 'package:flutter_client/src/platform/mobile_relay/mobile_relay_json_store.dart';

abstract class AgentTabOrderStore {
  const AgentTabOrderStore();

  Future<List<String>> load(Object portableData);

  Future<void> save(Object portableData, List<String> order);
}

class PlatformAgentTabOrderStore implements AgentTabOrderStore {
  const PlatformAgentTabOrderStore({
    MobileRelayJsonStore jsonStore = const MobileRelayJsonStore(),
  }) : _jsonStore = jsonStore;

  static const _fileName = 'agent-tab-order.json';

  final MobileRelayJsonStore _jsonStore;

  @override
  Future<List<String>> load(Object portableData) async {
    final decoded = await _jsonStore.read(portableData, _fileName);
    final rawOrder = decoded is Map
        ? decoded['order']
        : decoded is List
        ? decoded
        : null;
    return _normalizeOrder(rawOrder);
  }

  @override
  Future<void> save(Object portableData, List<String> order) {
    return _jsonStore.write(portableData, _fileName, {
      'schemaVersion': 1,
      'order': _normalizeOrder(order),
    }, lock: true);
  }

  List<String> _normalizeOrder(Object? value) {
    if (value is! List) {
      return const [];
    }
    final result = <String>[];
    final seen = <String>{};
    for (final item in value) {
      final id = item.toString().trim();
      if (id.isNotEmpty && seen.add(id)) {
        result.add(id);
      }
    }
    return List.unmodifiable(result);
  }
}
