import 'dart:ui' show Rect;

import 'package:licoup/src/contracts/presentation/dashboard_feature_order.dart';
import 'package:licoup/src/contracts/presentation/desktop_dock_layout.dart';
import 'package:licoup/src/frontend/shared/dashboard_feature_order_store.dart';
import 'package:licoup/src/frontend/shared/desktop_dock_layout_store.dart';
import 'package:licoup/src/contracts/conversation_profile.dart';
import 'package:licoup/src/frontend/shared/mascot/self_mascot_store.dart';
import 'package:licoup/src/frontend/shared/messaging/conversation_profile_store.dart';
import 'package:licoup/src/frontend/shared/messaging/messaging_unread_cursor_store.dart';
import 'package:licoup/src/contracts/presentation/window_chrome_models.dart';

export 'package:licoup/src/contracts/presentation/window_chrome_models.dart'
    show TrafficLightClusterEdges;

/// Reports a traffic-light anchor rectangle to the host window chrome —
/// window logical points, y down from the content top-left; null restores the
/// default top band. Resolves to the light cluster's leading and trailing
/// edges in the same coordinates, or null when the host cannot provide them.
typedef TrafficLightAnchorReporter =
    Future<TrafficLightClusterEdges?> Function(Rect? rect);

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

  /// Host window-move hook for title-bar chrome; a no-op until installed.
  static Future<void> Function() dragWindow = _noopWindowChrome;

  /// Host window-zoom hook for title-bar chrome; a no-op until installed.
  static Future<void> Function() toggleZoom = _noopWindowChrome;

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

  /// Default conversation unread-cursor store for the messaging sidebar;
  /// volatile until installed.
  static MessagingUnreadCursorStore Function() unreadCursorStore =
      _volatileUnreadCursorStore;

  /// Default self-mascot identity store for the avatar surfaces; volatile
  /// until installed.
  static SelfMascotStore Function() selfMascotStore = _volatileSelfMascotStore;

  /// Default conversation-profile registry store for the profile surfaces;
  /// volatile until installed.
  static ConversationProfileStore Function() conversationProfileStore =
      _volatileConversationProfileStore;

  /// The provisional self-mascot id for a process whose durable document does
  /// not exist yet. The composition root installs the platform layer's catalog
  /// pick; a harness that never composes ports keeps the deterministic 'lico'
  /// face instead of a random one.
  static String selfMascotSeed = 'lico';

  /// Installs the platform-backed implementations. Called once per process
  /// by the composition root; repeat calls simply replace the values.
  static void install({
    required Object portableData,
    required DashboardFeatureOrderStore Function() featureOrderStore,
    required DesktopDockLayoutStore Function() dockLayoutStore,
    required MessagingUnreadCursorStore Function() unreadCursorStore,
    required SelfMascotStore Function() selfMascotStore,
    required ConversationProfileStore Function() conversationProfileStore,
    required String selfMascotSeed,
    required TrafficLightAnchorReporter reportTrafficLightAnchor,
    required Future<void> Function() dragWindow,
    required Future<void> Function() toggleZoom,
  }) {
    ClientPlatformPorts.portableData = portableData;
    ClientPlatformPorts.featureOrderStore = featureOrderStore;
    ClientPlatformPorts.dockLayoutStore = dockLayoutStore;
    ClientPlatformPorts.unreadCursorStore = unreadCursorStore;
    ClientPlatformPorts.selfMascotStore = selfMascotStore;
    ClientPlatformPorts.conversationProfileStore = conversationProfileStore;
    ClientPlatformPorts.selfMascotSeed = selfMascotSeed;
    ClientPlatformPorts.reportTrafficLightAnchor = reportTrafficLightAnchor;
    ClientPlatformPorts.dragWindow = dragWindow;
    ClientPlatformPorts.toggleZoom = toggleZoom;
  }

  static Future<TrafficLightClusterEdges?> _dropTrafficLightAnchorReport(
    Rect? rect,
  ) async => null;

  static Future<void> _noopWindowChrome() async {}

  static DashboardFeatureOrderStore _volatileFeatureOrderStore() =>
      const _VolatileDashboardFeatureOrderStore();

  static DesktopDockLayoutStore _volatileDockLayoutStore() =>
      const _VolatileDesktopDockLayoutStore();

  static MessagingUnreadCursorStore _volatileUnreadCursorStore() =>
      const _VolatileMessagingUnreadCursorStore();

  static SelfMascotStore _volatileSelfMascotStore() =>
      const _VolatileSelfMascotStore();

  static ConversationProfileStore _volatileConversationProfileStore() =>
      const _VolatileConversationProfileStore();
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

final class _VolatileMessagingUnreadCursorStore
    extends MessagingUnreadCursorStore {
  const _VolatileMessagingUnreadCursorStore();

  @override
  Future<MessagingUnreadCursorSnapshot?> load(Object portableData) async =>
      null;

  @override
  Future<void> save(Object portableData, Map<String, int> cursors) async {}
}

final class _VolatileSelfMascotStore extends SelfMascotStore {
  const _VolatileSelfMascotStore();

  @override
  Future<String?> load(Object portableData) async => null;

  @override
  Future<void> save(Object portableData, String mascotId) async {}
}

final class _VolatileConversationProfileStore extends ConversationProfileStore {
  const _VolatileConversationProfileStore();

  @override
  Future<List<ConversationProfile>> load(Object portableData) async =>
      const <ConversationProfile>[];

  @override
  Future<void> save(
    Object portableData,
    List<ConversationProfile> profiles,
  ) async {}
}
