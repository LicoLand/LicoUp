import 'package:licoup/src/contracts/presentation/desktop_dock_layout.dart';
import 'package:licoup/src/frontend/shared/dashboard_feature_order_store.dart';
import 'package:licoup/src/frontend/shared/desktop_dock_layout_store.dart';
import 'package:licoup/src/platform/layout/dashboard_feature_order_store.dart';
import 'package:licoup/src/platform/layout/desktop_dock_layout_store.dart';

/// Adapts the platform file-backed 功能 order store onto the renderer-facing
/// port. The platform layer cannot import the frontend port, so the
/// composition root — the only layer allowed to wire both — translates here.
///
/// Also refreshes [DashboardFeatureOrderStore.lastKnownOrder] after every
/// completed load or save so a remounting sidebar starts from the known
/// order synchronously instead of flashing the default.
final class PlatformDashboardFeatureOrderStoreAdapter
    extends DashboardFeatureOrderStore {
  const PlatformDashboardFeatureOrderStoreAdapter([
    this._impl = const PlatformDashboardFeatureOrderStore(),
  ]);

  final PlatformDashboardFeatureOrderStore _impl;

  @override
  Future<List<String>> load(Object portableData) async {
    final order = await _impl.load(portableData);
    DashboardFeatureOrderStore.lastKnownOrder = order;
    return order;
  }

  @override
  Future<void> save(Object portableData, List<String> order) async {
    DashboardFeatureOrderStore.lastKnownOrder = await _impl.save(
      portableData,
      order,
    );
  }
}

/// Adapts the platform file-backed dock layout store onto the
/// renderer-facing port.
final class PlatformDesktopDockLayoutStoreAdapter
    extends DesktopDockLayoutStore {
  const PlatformDesktopDockLayoutStoreAdapter([
    this._impl = const PlatformDesktopDockLayoutStore(),
  ]);

  final PlatformDesktopDockLayoutStore _impl;

  @override
  Future<DesktopDockLayoutSnapshot> load(Object portableData) =>
      _impl.load(portableData);

  @override
  Future<void> save(Object portableData, DesktopDockLayoutSnapshot snapshot) =>
      _impl.save(portableData, snapshot);
}
