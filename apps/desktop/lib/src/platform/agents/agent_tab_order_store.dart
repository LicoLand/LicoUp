import 'package:licoup/src/platform/mobile_relay/mobile_relay_json_store.dart';
import 'package:licoup/src/contracts/target_management.dart';

abstract class AgentTabOrderStore implements TargetTabOrderRepository {
  const AgentTabOrderStore();

  @override
  Future<List<String>> load(Object portableData);

  @override
  Future<void> save(Object portableData, List<String> order);

  @override
  Future<List<String>> loadPinned(Object portableData);

  @override
  Future<void> savePinned(Object portableData, List<String> pinned);

  @override
  Future<bool> hasCustomPinnedIds(Object portableData);
}

class PlatformAgentTabOrderStore implements AgentTabOrderStore {
  const PlatformAgentTabOrderStore({
    MobileRelayJsonStore jsonStore = const MobileRelayJsonStore(),
  }) : _jsonStore = jsonStore;

  static const _fileName = 'agent-tab-order.json';

  final MobileRelayJsonStore _jsonStore;

  @override
  Future<List<String>> load(Object portableData) async {
    final decoded = await _readDocument(portableData);
    return _normalizeOrder(decoded?['order']);
  }

  @override
  Future<void> save(Object portableData, List<String> order) async {
    final decoded = await _readDocument(portableData) ?? <String, dynamic>{};
    await _jsonStore.write(portableData, _fileName, {
      'schemaVersion': 1,
      'order': _normalizeOrder(order),
      if (decoded.containsKey('pinned'))
        'pinned': _normalizeOrder(decoded['pinned']),
    }, lock: true);
  }

  @override
  Future<List<String>> loadPinned(Object portableData) async {
    final decoded = await _readDocument(portableData);
    return _normalizeOrder(decoded?['pinned']);
  }

  @override
  Future<void> savePinned(Object portableData, List<String> pinned) async {
    final decoded = await _readDocument(portableData) ?? <String, dynamic>{};
    await _jsonStore.write(portableData, _fileName, {
      'schemaVersion': 1,
      'order': _normalizeOrder(decoded['order']),
      'pinned': _normalizeOrder(pinned),
    }, lock: true);
  }

  @override
  Future<bool> hasCustomPinnedIds(Object portableData) async {
    final decoded = await _readDocument(portableData);
    return decoded?.containsKey('pinned') == true;
  }

  Future<Map<String, dynamic>?> _readDocument(Object portableData) async {
    final decoded = await _jsonStore.readCurrent(portableData, _fileName);
    if (decoded == null) {
      return null;
    }
    if (decoded is! Map || decoded['schemaVersion'] != 1) {
      throw StateError('agent_tab_order_requires_startup_migration');
    }
    return Map<String, dynamic>.from(decoded);
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
