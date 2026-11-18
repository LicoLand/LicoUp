import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/layout/layout_palette.dart';

/// Marker shared by profile-owned destination presentation strategies.
abstract interface class LayoutDestinationPresentation {}

/// What the top row of the conversation list column shows.
enum LayoutAgentsSidebarHeader {
  /// The native traffic-light zone, with the column actions on the right.
  trafficLights,

  /// The column title, with the column actions on the right. The shell hosts
  /// the traffic lights elsewhere.
  title,

  /// The centred search row — capsule plus column actions — with no title
  /// text and no light zone; the shell's rail owns the traffic lights.
  search,
}

/// How the conversation header is drawn on desktop.
enum LayoutConversationHeaderStyle {
  /// Floating glass capsules over the transcript.
  capsules,

  /// A flat full-width bar with a bottom hairline.
  bar,
}

/// Where a group conversation lists its members on desktop.
enum LayoutGroupMembersPlacement {
  /// A slim avatar capsule floating in the transcript band, hidden until the
  /// header toggle shows it.
  avatarStrip,

  /// A panel beside the chat with each member's name, role and status, shown
  /// until the header toggle hides it.
  sidePanel,
}

/// Profile-owned visual decisions used by the shared Agents business surface.
///
/// The shared feature remains responsible for business state and interaction
/// coordination. Every color, inset, frame, and profile-specific visibility
/// decision is supplied by the active profile implementation.
abstract interface class LayoutAgentsPresentation
    implements LayoutDestinationPresentation {
  Color canvasColor(LayoutPalette palette);

  /// Whether the workspace wraps sidebar and detail in its own window
  /// ground (fill plus the ambient layer). Flat shells (the Dashboard
  /// plain style) return false: the list column sits on the window
  /// backdrop and the detail's own ground owns the ambient layer inside
  /// its bounds.
  bool get canvasGroundsWorkspace;

  double get sidebarOuterHorizontalExtent;
  double get detailOuterHorizontalExtent;
  EdgeInsetsGeometry get expandedSidebarControlPadding;
  EdgeInsetsGeometry get collapsedSidebarControlPadding;
  bool get showExpandedSidebarControl;
  bool get showCollapsedSidebarControl;
  bool get showConversationSidebarControl;

  /// Whether the conversation list card carries the Dashboard bottom
  /// navigation row (功能/对话/设置). A profile whose own chrome already
  /// provides that navigation (the Desktop dock with its pinned 设置/功能
  /// icons and 对话 button) hides the row so the fullscreen-exclusive
  /// conversation app stays free of duplicate navigation.
  bool get showSidebarBottomNav;

  LayoutAgentsSidebarHeader get sidebarHeader;

  /// Whether the conversation list offers the All, Agents and Groups filter
  /// chips above its rows.
  bool get showConversationFilters;

  LayoutConversationHeaderStyle get conversationHeaderStyle;

  /// The flat conversation header bar's extent when [conversationHeaderStyle]
  /// is `bar`; capsule presentations still declare the default 60.
  double get conversationHeaderBarExtent;

  LayoutGroupMembersPlacement get groupMembersPlacement;

  Widget frameWorkspace(
    BuildContext context, {
    required Key key,
    required Widget child,
  });

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
  /// True when the profile's shell navigation hosts the settings section
  /// index (for example as expandable sub-items under the Settings
  /// destination). The settings panel then renders its content full width and
  /// keeps the section tab channel as the shared selection source.
  bool get indexHostedByNavigation;

  EdgeInsetsGeometry get contentPadding;
  EdgeInsetsGeometry get indexPadding;
  EdgeInsetsGeometry get sectionHeaderPadding;
  EdgeInsetsGeometry get rowPadding;
  EdgeInsetsGeometry get selectorGridPadding;

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

LayoutAgentsPresentation layoutAgentsPresentationOf(BuildContext context) =>
    LayoutDestinationPresentationScope.agentsOf(context);

LayoutAgentsPresentation? maybeLayoutAgentsPresentationOf(
  BuildContext context,
) => LayoutDestinationPresentationScope.maybeOf(context)?.agents;

LayoutSettingsPresentation layoutSettingsPresentationOf(BuildContext context) =>
    LayoutDestinationPresentationScope.settingsOf(context);
