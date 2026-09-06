import 'package:licoup/src/contracts/presentation/dashboard_feature_order.dart';
import 'package:licoup/src/platform/mobile_relay/mobile_relay_json_store.dart';

/// File-backed store for the Dashboard 功能 list order
/// (`dashboard-feature-order.json`).
///
/// Mirrors the agent tab order store idiom: one JSON document with a schema
/// version, atomic temp-file replace on save, and a tolerant load — a missing
/// document yields the frozen default order and unknown stored ids are
/// ignored so older or foreign payloads can never break the sidebar. The
/// composition root adapts this onto the renderer-facing
/// `DashboardFeatureOrderStore` port.
final class PlatformDashboardFeatureOrderStore {
  const PlatformDashboardFeatureOrderStore({
    MobileRelayJsonStore jsonStore = const MobileRelayJsonStore(),
  }) : _jsonStore = jsonStore;

  static const _fileName = 'dashboard-feature-order.json';

  final MobileRelayJsonStore _jsonStore;

  Future<List<String>> load(Object portableData) async {
    final decoded = await _readDocument(portableData);
    return _resolveOrder(decoded?['order']);
  }

  /// Persists [order] and returns the normalized order actually written, so
  /// the wiring layer can refresh the renderer's last-known-order seed.
  Future<List<String>> save(Object portableData, List<String> order) async {
    final resolved = _resolveOrder(order);
    await _jsonStore.write(portableData, _fileName, {
      'schemaVersion': 1,
      'order': resolved,
    }, lock: true);
    return resolved;
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
    final known = DashboardFeatureOrder.defaultOrder;
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
