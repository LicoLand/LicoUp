import 'package:flutter/material.dart';

/// Feature-owned chrome content that layout profiles may host in their shell
/// chrome without importing feature code: the conversation tab strip and the
/// notification bell. Built by composition from semantic bindings and
/// feature-widget factories; consumed through [LayoutChromeFeaturesScope].
abstract interface class LayoutChromeFeatures {
  /// The conversation pill-tab strip for the chrome band. Feature-owned;
  /// reads its own state and handles its own scrolling.
  Widget buildConversationTabs(BuildContext context);

  /// The notification bell with activity badge and dropdown. Feature-owned.
  Widget buildNotificationBell(BuildContext context);

  /// An auxiliary chrome panel owned by the active profile shell (for
  /// example the messaging profile page). When present, chrome features that
  /// navigate elsewhere — opening a conversation from a tab or a
  /// notification — set it to false so the panel closes. Profiles without
  /// such a panel leave this null.
  ValueNotifier<bool>? get auxChromePanelOpen => null;
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
