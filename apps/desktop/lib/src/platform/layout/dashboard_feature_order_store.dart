import 'package:licoup/src/platform/mobile_relay/mobile_relay_json_store.dart';

/// Durable order of the Dashboard 功能 list (`dashboard-feature-order.json`).
///
/// Mirrors the agent tab order store idiom: one JSON document with a schema
/// version, atomic temp-file replace on save, and a tolerant load — a missing
/// document yields the frozen default order and unknown stored ids are
/// ignored so older or foreign payloads can never break the sidebar.
abstract class DashboardFeatureOrderStore {
  const DashboardFeatureOrderStore();

  /// The seven frozen 功能 entries in their default order.
  static const defaultOrder = <String>[
    'agentHub',
    'modelGateway',
    'mobilePairing',
    'statsPanel',
    'pluginManagement',
    'skillHub',
    'chatChannels',
  ];

  /// The stored order with unknown ids dropped and any missing default ids
  /// appended in default order; [defaultOrder] itself when nothing is stored.
  Future<List<String>> load(Object portableData);

  /// Persists [order] (normalized to known ids) with an atomic replace.
  Future<void> save(Object portableData, List<String> order);
}

final class PlatformDashboardFeatureOrderStore
    extends DashboardFeatureOrderStore {
  const PlatformDashboardFeatureOrderStore({
    MobileRelayJsonStore jsonStore = const MobileRelayJsonStore(),
  }) : _jsonStore = jsonStore;

  static const _fileName = 'dashboard-feature-order.json';

  /// Last resolved order for this process. Lets a remounting sidebar start
  /// from the known order synchronously instead of flashing the default.
  static List<String>? _lastKnownOrder;

  /// The last order resolved in this run, when any load or save completed.
  static List<String>? peekLastKnownOrder() => _lastKnownOrder;

  final MobileRelayJsonStore _jsonStore;

  @override
  Future<List<String>> load(Object portableData) async {
    final decoded = await _readDocument(portableData);
    final order = _resolveOrder(decoded?['order']);
    _lastKnownOrder = order;
    return order;
  }

  @override
  Future<void> save(Object portableData, List<String> order) async {
    final resolved = _resolveOrder(order);
    await _jsonStore.write(portableData, _fileName, {
      'schemaVersion': 1,
      'order': resolved,
    }, lock: true);
    _lastKnownOrder = resolved;
  }

  Future<Map<String, dynamic>?> _readDocument(Object portableData) async {
    final decoded = await _jsonStore.readCurrent(portableData, _fileName);
    if (decoded == null) {
      return null;
    }
    if (decoded is! Map || decoded['schemaVersion'] != 1) {
      throw StateError('dashboard_feature_order_requires_startup_migration');
    }
    return Map<String, dynamic>.from(decoded);
  }

  List<String> _resolveOrder(Object? value) {
    final known = DashboardFeatureOrderStore.defaultOrder;
    final result = <String>[];
    if (value is List) {
      for (final item in value) {
        final id = item.toString().trim();
        if (id.isNotEmpty && known.contains(id) && !result.contains(id)) {
          result.add(id);
        }
      }
    }
    for (final id in known) {
      if (!result.contains(id)) {
        result.add(id);
      }
    }
    return List.unmodifiable(result);
  }
}
