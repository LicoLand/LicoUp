import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/shared/ui/lico_toast.dart';
import 'package:licoup/src/presentation/chrome/chrome_projection.dart';

/// Chrome-visible state of the built-in Collaboration app.
final class LayoutCollaborationAppState {
  const LayoutCollaborationAppState({
    this.subtitle = '',
    this.pendingDecisions = 0,
  });

  /// The conversation the flowchart follows; empty when none is selected.
  final String subtitle;

  /// Gates waiting for the user plus a held plan proposal; the dock badge.
  final int pendingDecisions;

  @override
  bool operator ==(Object other) =>
      other is LayoutCollaborationAppState &&
      other.subtitle == subtitle &&
      other.pendingDecisions == pendingDecisions;

  @override
  int get hashCode => Object.hash(subtitle, pendingDecisions);
}

/// One installed UI plugin as the shell chrome sees it.
final class LayoutPluginWindowSummary {
  const LayoutPluginWindowSummary({
    required this.id,
    required this.name,
    required this.official,
    required this.open,
  });

  final String id;
  final String name;

  /// Published by LicoLand; every other publisher is third party.
  final bool official;

  /// Whether the plugin's window is open in this session.
  final bool open;

  @override
  bool operator ==(Object other) =>
      other is LayoutPluginWindowSummary &&
      other.id == id &&
      other.name == name &&
      other.official == official &&
      other.open == open;

  @override
  int get hashCode => Object.hash(id, name, official, open);
}

/// A profile app the quick switcher lists beside the conversations.
final class LayoutQuickSwitcherApp {
  const LayoutQuickSwitcherApp({
    required this.id,
    required this.label,
    required this.icon,
  });

  final String id;
  final String label;
  final IconData icon;
}

/// Feature-owned chrome content that layout profiles may host in their shell
/// chrome without importing feature code: the Desktop work-area apps that
/// are feature surfaces (Collaboration, plugin windows), the quick switcher,
/// the chrome notification-notices exposure, and the self avatar / profile
/// popover. Built by composition from semantic bindings and feature-widget
/// factories; consumed through [LayoutChromeFeaturesScope].
abstract interface class LayoutChromeFeatures {
  /// The chrome notification-notices exposure consumed by
  /// [LicoToastNoticesListener] in desktop shells. Replaces the retired
  /// notification bell: snapshots mirror the chrome projection's notices and
  /// auto-reveal revisions without changing how notices are produced.
  ValueListenable<LicoToastNoticesSnapshot> get notificationNotices;

  /// An auxiliary chrome panel owned by the active profile shell (for
  /// example the messaging profile page). When present, chrome features that
  /// navigate elsewhere set it to false so the panel closes. Profiles without
  /// such a panel leave this null.
  ValueNotifier<bool>? get auxChromePanelOpen => null;

  /// Activate a completion notice only after an explicit user action.
  /// Arrival never calls this.
  void activateOperationNotice(ChromeOperationNotificationProjection notice) {}

  /// The Collaboration flowchart following the selected conversation.
  Widget buildCollaborationApp(BuildContext context);

  ValueListenable<LayoutCollaborationAppState> get collaborationApp;

  /// Installed UI plugins in catalog order.
  ValueListenable<List<LayoutPluginWindowSummary>> get pluginWindows;

  void openPluginWindow(String pluginId);

  void closePluginWindow(String pluginId);

  /// The content area of an open plugin window, including its loading,
  /// permission, error, offline and unsupported states.
  Widget buildPluginWindow(BuildContext context, String pluginId);

  /// The plugin window's title-row actions: the sandbox chip with its
  /// declared permissions, reload, and the window menu, whose entries call
  /// back into the shell that owns the window.
  Widget buildPluginWindowActions(
    BuildContext context,
    String pluginId, {
    required VoidCallback onOpenPermissionSettings,
    required VoidCallback onClose,
  });

  /// The quick switcher over conversations and [apps]; choosing an app
  /// calls [onOpenApp] with its id.
  Future<void> openQuickSwitcher(
    BuildContext context, {
    required List<LayoutQuickSwitcherApp> apps,
    required ValueChanged<String> onOpenApp,
  });

  /// The local user's avatar widget for profile chrome such as the navigation
  /// rail.
  Widget buildSelfAvatar(
    BuildContext context, {
    required double size,
    String? mascotId,
  });

  /// Opens the local user's floating self-profile popover anchored to
  /// [anchorRect].
  Future<void> openSelfProfile(
    BuildContext context, {
    required Rect anchorRect,
    String? mascotId,
    required ValueChanged<String> onMascotChanged,
    required VoidCallback onOpenSettings,
  });
}

/// Makes the host's feature-owned chrome content available to profile shells
/// without exposing controllers or feature imports across the profile
/// boundary. Profiles that do not use chrome features simply never read it.
final class LayoutChromeFeaturesScope extends InheritedWidget {
  const LayoutChromeFeaturesScope({
    super.key,
    required this.features,
    required super.child,
  });

  final LayoutChromeFeatures? features;

  static LayoutChromeFeatures? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<LayoutChromeFeaturesScope>()
      ?.features;

  @override
  bool updateShouldNotify(LayoutChromeFeaturesScope oldWidget) =>
      !identical(oldWidget.features, features);
}
