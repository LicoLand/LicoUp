import 'package:flutter/material.dart';

import 'package:flutter_client/src/frontend/layout/layout_palette.dart';

/// Marker shared by profile-owned destination presentation strategies.
abstract interface class LayoutDestinationPresentation {}

/// Profile-owned visual decisions used by the shared Agents business surface.
///
/// The shared feature remains responsible for business state and interaction
/// orchestration. Every color, inset, frame, and profile-specific visibility
/// decision is supplied by the active profile implementation.
abstract interface class LayoutAgentsPresentation
    implements LayoutDestinationPresentation {
  Color canvasColor(LayoutPalette palette);

  double get sidebarOuterHorizontalExtent;
  double get detailOuterHorizontalExtent;
  EdgeInsetsGeometry get expandedSidebarControlPadding;
  EdgeInsetsGeometry get collapsedSidebarControlPadding;
  bool get showExpandedSidebarControl;
  bool get showCollapsedSidebarControl;
  bool get showConversationSidebarControl;

  Widget frameSidebar(
    BuildContext context, {
    required Key key,
    required Widget child,
  });

  Widget frameDetail(
    BuildContext context, {
    required Key key,
    required bool sidebarCollapsed,
    required Widget child,
  });
}

/// Profile-owned visual decisions used by the shared Settings business surface.
abstract interface class LayoutSettingsPresentation
    implements LayoutDestinationPresentation {
  EdgeInsetsGeometry get contentPadding;
  EdgeInsetsGeometry get indexPadding;
  EdgeInsetsGeometry get sectionHeaderPadding;
  EdgeInsetsGeometry get rowPadding;
  EdgeInsetsGeometry get selectorGridPadding;
  EdgeInsetsGeometry get selectorActionPadding;

  Widget frameIndex(
    BuildContext context, {
    required bool hovered,
    required Widget child,
  });

  Widget frameSection(
    BuildContext context, {
    required Key key,
    required Widget child,
  });

  Widget frameSelector(BuildContext context, {required Widget child});
}

/// Makes the active profile's destination strategies available to business UI
/// without exposing a profile identity or application controller.
final class LayoutDestinationPresentationScope extends InheritedWidget {
  const LayoutDestinationPresentationScope({
    super.key,
    this.agents,
    this.settings,
    required super.child,
  });

  final LayoutAgentsPresentation? agents;
  final LayoutSettingsPresentation? settings;

  static LayoutDestinationPresentationScope? maybeOf(
    BuildContext context,
  ) => context
      .dependOnInheritedWidgetOfExactType<LayoutDestinationPresentationScope>();

  static LayoutAgentsPresentation agentsOf(BuildContext context) {
    final value = maybeOf(context)?.agents;
    if (value == null) {
      throw StateError('layout_agents_presentation_missing');
    }
    return value;
  }

  static LayoutSettingsPresentation settingsOf(BuildContext context) {
    final value = maybeOf(context)?.settings;
    if (value == null) {
      throw StateError('layout_settings_presentation_missing');
    }
    return value;
  }

  @override
  bool updateShouldNotify(LayoutDestinationPresentationScope oldWidget) =>
      !identical(oldWidget.agents, agents) ||
      !identical(oldWidget.settings, settings);
}
