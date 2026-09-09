import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/shared/ui/lico_toast.dart';
import 'package:licoup/src/presentation/chrome/chrome_projection.dart';

/// Feature-owned chrome content that layout profiles may host in their shell
/// chrome without importing feature code: the Desktop dock composer and the
/// chrome notification-notices exposure. Built by composition from semantic
/// bindings and feature-widget factories; consumed through
/// [LayoutChromeFeaturesScope].
abstract interface class LayoutChromeFeatures {
  /// The conversation message composer hosted by the Desktop dock capsule
  /// while the conversation fullscreen app is active. Feature-owned; reads
  /// its own projections and sends through the shared conversation intents.
  Widget buildDockComposer(BuildContext context);

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
