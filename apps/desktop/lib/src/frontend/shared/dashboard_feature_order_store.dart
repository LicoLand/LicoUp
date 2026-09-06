import 'package:licoup/src/contracts/presentation/dashboard_feature_order.dart';

/// Renderer-facing port for the durable Dashboard 功能 list order
/// (`dashboard-feature-order.json`).
///
/// The sidebar depends on this port; the platform layer ships the file-backed
/// implementation without naming it here, and the composition root adapts one
/// onto the other (`PlatformDashboardFeatureOrderStoreAdapter`). The
/// `portableData` argument stays an opaque [Object] so the port never names
/// the platform data-root type.
abstract class DashboardFeatureOrderStore {
  const DashboardFeatureOrderStore();

  /// The last order resolved by the installed store in this process.
  ///
  /// The composition adapter updates this on every completed load or save so
  /// a remounting sidebar can start from the known order synchronously
  /// instead of flashing the default. Test doubles never touch it, keeping
  /// widget tests isolated from each other.
  static List<String>? lastKnownOrder;

  /// The stored order with unknown ids dropped and any missing default ids
  /// appended in default order; [DashboardFeatureOrder.defaultOrder] itself
  /// when nothing is stored.
  Future<List<String>> load(Object portableData);

  /// Persists [order] (normalized to known ids) with an atomic replace.
  Future<void> save(Object portableData, List<String> order);
}
