import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_destination_presentation.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/tokens/dashboard_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/ui/lico_pane_card.dart';
import 'package:licoup/src/frontend/shared/ui/conversation_material_scope.dart';
import 'package:licoup/src/frontend/shared/ui/lico_content_spacing.dart';

/// Destinations whose body sits flush on the clear window veil inside the
/// chromeless main content region. These use a transparent canvas; they do
/// not paint an opaque surface fill of their own.
const Set<ClientSection> dashboardMainContentCardDestinations = <ClientSection>{
  ClientSection.agents,
  ClientSection.skillHub,
  ClientSection.pluginManagement,
  ClientSection.agentHub,
  ClientSection.monitoring,
  ClientSection.models,
  ClientSection.devices,
  ClientSection.settings,
};

const LayoutAgentsPresentation dashboardCardAgentsPresentation =
    DashboardDesktopAgentsPresentation();
const LayoutSettingsPresentation dashboardCardSettingsPresentation =
    DashboardDesktopSettingsPresentation();

/// Dashboard desktop Agents: the window veil itself is the conversation
/// surface (the main content region is chromeless); the conversation list is
/// the single floating glass card; the chat pane is flush with the window.
/// The list IS the sidebar, so no collapse controls are offered.
final class DashboardDesktopAgentsPresentation
    implements LayoutAgentsPresentation {
  const DashboardDesktopAgentsPresentation();

  /// Transparent so the clear window veil is the shared conversation
  /// background (the list card floats above it).
  @override
  Color canvasColor(LayoutPalette palette) => Colors.transparent;

  // The shell ground covers the whole window; the conversation sits on
  // it directly — no workspace fill and no second ambient layer.
  @override
  bool get canvasGroundsWorkspace => false;

  @override
  double get sidebarOuterHorizontalExtent =>
      MessagingDesktopMetrics.conversationListCardInset;

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

  @override
  bool get showSidebarBottomNav => true;

  @override
  LayoutAgentsSidebarHeader get sidebarHeader =>
      LayoutAgentsSidebarHeader.trafficLights;

  @override
  bool get showConversationFilters => false;

  @override
  double get conversationHeaderBarExtent => 60;

  @override
  LayoutConversationHeaderStyle get conversationHeaderStyle =>
      LayoutConversationHeaderStyle.capsules;

  @override
  LayoutGroupMembersPlacement get groupMembersPlacement =>
      LayoutGroupMembersPlacement.avatarStrip;

  @override
  Widget frameWorkspace(
    BuildContext context, {
    required Key key,
    required Widget child,
  }) => ConversationMaterialScope(
    key: key,
    opaqueBubbles: true,
    child: Card(child: child),
  );

  @override
  Widget frameSidebar(
    BuildContext context, {
    required Key key,
    required Widget child,
  }) {
    // One floating pane card over the shell ground — smoke glass over the
    // galaxy in dark, the light card fill with its hairline in light.
    const inset = MessagingDesktopMetrics.conversationListCardInset;
    return Padding(
      padding: const EdgeInsets.fromLTRB(inset, inset, 0, inset),
      child: LicoPaneCard(
        key: key,
        navGlass: true,
        borderRadius: BorderRadius.circular(14),
        child: child,
      ),
    );
  }

  @override
  Widget frameDetail(
    BuildContext context, {
    required Key key,
    required bool sidebarCollapsed,
    required Widget child,
  }) => KeyedSubtree(key: key, child: child);
}

/// Dashboard desktop Settings: opaque window ground inside the main content
/// card, same as the conversation surfaces; section index and content share it.
final class DashboardDesktopSettingsPresentation
    implements LayoutSettingsPresentation {
  const DashboardDesktopSettingsPresentation();

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
  }) => ConversationMaterialScope(
    key: key,
    opaqueBubbles: true,
    child: Card(child: child),
  );

  @override
  Widget frameSelector(BuildContext context, {required Widget child}) => child;
}
