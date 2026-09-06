import 'dart:ui' show Rect;

import 'package:licoup/src/contracts/presentation/dashboard_feature_order.dart';
import 'package:licoup/src/contracts/presentation/desktop_dock_layout.dart';
import 'package:licoup/src/frontend/shared/dashboard_feature_order_store.dart';
import 'package:licoup/src/frontend/shared/desktop_dock_layout_store.dart';

/// Reports a traffic-light anchor rectangle to the host window chrome —
/// window logical points, y down from the content top-left; null restores the
/// default top band.
typedef TrafficLightAnchorReporter = Future<void> Function(Rect? rect);

/// Platform services that renderer code calls into at runtime.
///
/// Frontend code must never import the platform layer, so the composition
/// root (`ClientAppComposition`) installs the platform-backed implementations
/// at startup. The defaults stay hermetic — anchor reports are dropped and
/// the presentation-state stores are volatile in-memory — so widget tests
/// never touch the host's real state directory or window chrome.
final class ClientPlatformPorts {
  const ClientPlatformPorts._();

  /// Host window-chrome reporter; a no-op until installed.
  static TrafficLightAnchorReporter reportTrafficLightAnchor =
      _dropTrafficLightAnchorReport;

  /// The process shared portable-data root, passed through as an opaque
  /// value for the store contracts; null until installed.
  static Object? portableData;

  /// Default 功能 order store for sidebars without an explicit
  /// `MessagingFeatureOrderScope`; volatile until installed.
  static DashboardFeatureOrderStore Function() featureOrderStore =
      _volatileFeatureOrderStore;

  /// Default dock layout store for shells without an explicit controller;
  /// volatile until installed.
  static DesktopDockLayoutStore Function() dockLayoutStore =
      _volatileDockLayoutStore;

  /// Installs the platform-backed implementations. Called once per process
  /// by the composition root; repeat calls simply replace the values.
  static void install({
    required Object portableData,
    required DashboardFeatureOrderStore Function() featureOrderStore,
    required DesktopDockLayoutStore Function() dockLayoutStore,
    required TrafficLightAnchorReporter reportTrafficLightAnchor,
  }) {
    ClientPlatformPorts.portableData = portableData;
    ClientPlatformPorts.featureOrderStore = featureOrderStore;
    ClientPlatformPorts.dockLayoutStore = dockLayoutStore;
    ClientPlatformPorts.reportTrafficLightAnchor = reportTrafficLightAnchor;
  }

  static Future<void> _dropTrafficLightAnchorReport(Rect? rect) async {}

  static DashboardFeatureOrderStore _volatileFeatureOrderStore() =>
      const _VolatileDashboardFeatureOrderStore();

  static DesktopDockLayoutStore _volatileDockLayoutStore() =>
      const _VolatileDesktopDockLayoutStore();
}

final class _VolatileDashboardFeatureOrderStore
    extends DashboardFeatureOrderStore {
  const _VolatileDashboardFeatureOrderStore();

  @override
  Future<List<String>> load(Object portableData) async =>
      DashboardFeatureOrder.defaultOrder;

  @override
  Future<void> save(Object portableData, List<String> order) async {}
}

final class _VolatileDesktopDockLayoutStore extends DesktopDockLayoutStore {
  const _VolatileDesktopDockLayoutStore();

  @override
  Future<DesktopDockLayoutSnapshot> load(Object portableData) async =>
      const DesktopDockLayoutSnapshot(entries: []);

  @override
  Future<void> save(
    Object portableData,
    DesktopDockLayoutSnapshot snapshot,
  ) async {}
}
