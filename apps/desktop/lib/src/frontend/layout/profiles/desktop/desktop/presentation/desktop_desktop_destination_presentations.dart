import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/layout/layout_destination_presentation.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/tokens/desktop_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/ui/lico_pane_card.dart';

import 'package:licoup/src/frontend/shared/ui/lico_content_spacing.dart';

const LayoutAgentsPresentation desktopDesktopAgentsPresentation =
    DesktopDesktopAgentsPresentation();
const LayoutSettingsPresentation desktopDesktopSettingsPresentation =
    DesktopDesktopSettingsPresentation();

/// Desktop conversation presentation: a transparent canvas inside the chat
/// sidebar card. The shell hosts the conversation list as the avatar column
/// and the header switcher, so the list frame only applies when the shared
/// workspace falls back to its own list layout.
final class DesktopDesktopAgentsPresentation
    implements LayoutAgentsPresentation {
  const DesktopDesktopAgentsPresentation();

  @override
  Color canvasColor(LayoutPalette palette) => Colors.transparent;

  @override
  bool get canvasGroundsWorkspace => true;

  @override
  double get sidebarOuterHorizontalExtent => 0;

  @override
  double get detailOuterHorizontalExtent => 0;

  @override
  EdgeInsetsGeometry get expandedSidebarControlPadding => EdgeInsets.zero;

  @override
  EdgeInsetsGeometry get collapsedSidebarControlPadding => EdgeInsets.zero;

  @override
  bool get showExpandedSidebarControl => false;

  @override
  bool get showCollapsedSidebarControl => false;

  @override
  bool get showConversationSidebarControl => false;

  // The Desktop dock already carries every app and Settings, so the
  // conversation list renders no Dashboard nav row.
  @override
  bool get showSidebarBottomNav => false;

  @override
  LayoutAgentsSidebarHeader get sidebarHeader =>
      LayoutAgentsSidebarHeader.trafficLights;

  @override
  bool get showConversationFilters => false;

  @override
  @override
  double get conversationHeaderBarExtent => 52;

  @override
  LayoutConversationHeaderStyle get conversationHeaderStyle =>
      LayoutConversationHeaderStyle.bar;

  @override
  LayoutGroupMembersPlacement get groupMembersPlacement =>
      LayoutGroupMembersPlacement.avatarStrip;

  @override
  Widget frameWorkspace(
    BuildContext context, {
    required Key key,
    required Widget child,
  }) => KeyedSubtree(
    key: key,
    child: Card(child: child),
  );

  @override
  Widget frameSidebar(
    BuildContext context, {
    required Key key,
    required Widget child,
  }) => LicoPaneCard(
    key: key,
    borderRadius: BorderRadius.circular(DesktopDesktopMetrics.paneRadius),
    child: child,
  );

  @override
  Widget frameDetail(
    BuildContext context, {
    required Key key,
    required bool sidebarCollapsed,
    required Widget child,
  }) => KeyedSubtree(
    key: key,
    child: Card(child: child),
  );
}

/// Desktop settings presentation: the Desktop settings surface carries no
/// section index at all — the work area is already the navigation slot, and
/// a second rail inside settings is redundant chrome. Reporting
/// `indexHostedByNavigation` keeps the shared panel from rendering its own
/// rail, so the sections read as one continuous content page (scroll-spy
/// still publishes the shared section tab channel).
final class DesktopDesktopSettingsPresentation
    implements LayoutSettingsPresentation {
  const DesktopDesktopSettingsPresentation();

  @override
  bool get indexHostedByNavigation => true;

  @override
  EdgeInsetsGeometry get contentPadding => EdgeInsets.zero;

  @override
  EdgeInsetsGeometry get indexPadding =>
      const EdgeInsets.symmetric(vertical: LicoContentSpacing.compact);

  @override
  EdgeInsetsGeometry get sectionHeaderPadding => const EdgeInsets.fromLTRB(
    20,
    LicoContentSpacing.item,
    20,
    LicoContentSpacing.compact,
  );

  @override
  EdgeInsetsGeometry get rowPadding => const EdgeInsets.fromLTRB(
    20,
    LicoContentSpacing.item,
    20,
    LicoContentSpacing.item,
  );

  @override
  EdgeInsetsGeometry get selectorGridPadding =>
      // The selector cards align with the setting rows' left edge.
      const EdgeInsets.fromLTRB(20, LicoContentSpacing.item, 20, 0);

  @override
  Widget frameIndex(
    BuildContext context, {
    required bool hovered,
    required Widget child,
  }) => child;

  @override
  Widget frameSection(
    BuildContext context, {
    required Key key,
    required Widget child,
  }) => KeyedSubtree(
    key: key,
    child: Card(child: child),
  );

  @override
  Widget frameSelector(BuildContext context, {required Widget child}) => child;
}
