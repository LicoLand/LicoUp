import 'dart:async' show Zone;

import 'package:licoup/src/contracts/conversation_profile.dart';
import 'package:licoup/src/contracts/presentation/desktop_dock_layout.dart';
import 'package:licoup/src/frontend/shared/dashboard_feature_order_store.dart';
import 'package:licoup/src/frontend/shared/desktop_dock_layout_store.dart';
import 'package:licoup/src/frontend/shared/mascot/self_mascot_store.dart';
import 'package:licoup/src/frontend/shared/messaging/conversation_profile_store.dart';
import 'package:licoup/src/frontend/shared/messaging/messaging_unread_cursor_store.dart';
import 'package:licoup/src/platform/layout/dashboard_feature_order_store.dart';
import 'package:licoup/src/platform/layout/desktop_dock_layout_store.dart';
import 'package:licoup/src/platform/messaging/conversation_profile_store.dart';
import 'package:licoup/src/platform/messaging/messaging_unread_cursor_store.dart';
import 'package:licoup/src/platform/presentation/self_mascot_identity_store.dart';
import 'package:licoup/src/platform/storage/portable_data_root.dart';

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

/// Adapts the platform file-backed unread-cursor store onto the
/// renderer-facing port and refreshes the last-known seed after every
/// completed load or save.
///
/// The durable read and write run in the root zone: the sidebar fires them
/// unawaited, so they must complete against the real event loop even when the
/// caller's zone (a widget test's fake-async zone, for example) never drains
/// another microtask.
final class PlatformMessagingUnreadCursorStoreAdapter
    extends MessagingUnreadCursorStore {
  const PlatformMessagingUnreadCursorStoreAdapter([
    this._impl = const PlatformMessagingUnreadCursorStore(),
  ]);

  final PlatformMessagingUnreadCursorStore _impl;

  @override
  Future<MessagingUnreadCursorSnapshot?> load(Object portableData) =>
      Zone.root.run(() => _impl.load(portableData)).then((document) {
        if (document == null) {
          return null;
        }
        MessagingUnreadCursorStore.lastKnownCursors = document.cursors;
        return MessagingUnreadCursorSnapshot(
          cursors: document.cursors,
          baselineAtUnixMs: document.baselineAtUnixMs,
        );
      });

  @override
  Future<void> save(Object portableData, Map<String, int> cursors) =>
      // The whole chain stays inside the root zone: a fake-async caller's
      // await may never resume, so the stale-write verdict must be decided
      // where the durable write actually runs.
      Zone.root.run(() async {
        try {
          MessagingUnreadCursorStore.lastKnownCursors = await _impl.save(
            portableData,
            cursors,
          );
        } catch (error) {
          if (!_isStaleWriteAfterClose(error)) rethrow;
        }
      });
}

/// The shared late-write verdict for fire-and-forget stores: a save still in
/// flight when the composition's data-home write admission closes is stale —
/// the next launch reloads the durable document. Dropping it keeps
/// `unawaited` callers free of unhandled async errors; anything else still
/// propagates.
bool _isStaleWriteAfterClose(Object error) =>
    isDataHomeWriteAdmissionClosed(error);

/// Adapts the platform file-backed self-mascot identity store onto the
/// renderer-facing port and refreshes the last-known id after every
/// completed load or save.
///
/// The durable read and write run in the root zone: hydration and the
/// persist-on-change listener fire unawaited, so they must complete against
/// the real event loop even when the caller's zone (a widget test's
/// fake-async zone, for example) never drains another microtask.
final class PlatformSelfMascotStoreAdapter extends SelfMascotStore {
  const PlatformSelfMascotStoreAdapter([
    this._impl = const PlatformSelfMascotIdentityStore(),
  ]);

  final PlatformSelfMascotIdentityStore _impl;

  @override
  Future<String?> load(Object portableData) =>
      Zone.root.run(() => _impl.load(portableData)).then((id) {
        if (id != null) {
          SelfMascotStore.lastKnownId = id;
        }
        return id;
      });

  @override
  Future<void> save(Object portableData, String mascotId) => Zone.root.run(
    () async {
      try {
        SelfMascotStore.lastKnownId = await _impl.save(portableData, mascotId);
      } catch (error) {
        if (!_isStaleWriteAfterClose(error)) rethrow;
      }
    },
  );
}

/// Adapts the platform file-backed conversation-profile store onto the
/// renderer-facing port.
///
/// The durable read and write run in the root zone: hydration and the
/// persist-on-change listener fire unawaited, so they must complete against
/// the real event loop even when the caller's zone never drains another
/// microtask.
final class PlatformConversationProfileStoreAdapter
    extends ConversationProfileStore {
  const PlatformConversationProfileStoreAdapter([
    this._impl = const PlatformConversationProfileStore(),
  ]);

  final PlatformConversationProfileStore _impl;

  @override
  Future<List<ConversationProfile>> load(Object portableData) =>
      Zone.root.run(() => _impl.load(portableData));

  @override
  Future<void> save(Object portableData, List<ConversationProfile> profiles) =>
      Zone.root.run(() async {
        try {
          await _impl.save(portableData, profiles);
        } catch (error) {
          if (!_isStaleWriteAfterClose(error)) rethrow;
        }
      });
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
