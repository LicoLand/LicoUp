import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/layout/layout_destination_presentation.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/shared/ui/continuous_stroke.dart';
import 'package:licoup/src/frontend/shared/ui/conversation_material_scope.dart';
import 'package:licoup/src/frontend/shared/ui/lico_window_ground.dart';
import 'package:licoup/src/frontend/shared/ui/lico_content_spacing.dart';

const LayoutAgentsPresentation dashboardPlainAgentsPresentation =
    DashboardPlainAgentsPresentation();
const LayoutSettingsPresentation dashboardPlainSettingsPresentation =
    DashboardPlainSettingsPresentation();

/// Dashboard plain Agents: the list column and the chat pane sit side by
/// side over the window ground, separated by one hairline. The list column
/// paints no fill and opens with the centred search row; the rail beside it
/// owns navigation and the traffic lights, so the column has no bottom tabs
/// and no light zone. The chat pane's own window ground paints the ambient
/// layer inside the detail bounds only.
final class DashboardPlainAgentsPresentation
    implements LayoutAgentsPresentation {
  const DashboardPlainAgentsPresentation();

  @override
  Color canvasColor(LayoutPalette palette) => palette.background;

  @override
  bool get canvasGroundsWorkspace => false;

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

  @override
  bool get showSidebarBottomNav => false;

  @override
  LayoutAgentsSidebarHeader get sidebarHeader =>
      LayoutAgentsSidebarHeader.search;

  @override
  bool get showConversationFilters => true;

  @override
  double get conversationHeaderBarExtent => 60;

  @override
  LayoutConversationHeaderStyle get conversationHeaderStyle =>
      LayoutConversationHeaderStyle.bar;

  @override
  LayoutGroupMembersPlacement get groupMembersPlacement =>
      LayoutGroupMembersPlacement.sidePanel;

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
  }) =>
      // No fill: the list column sits on the window ground and the detail
      // begins at its right hairline.
      CustomPaint(
        key: key,
        foregroundPainter: ContinuousEdgeHairlinePainter(
          color: context.layoutPalette.line,
          edge: AxisDirection.right,
        ),
        child: child,
      );

  @override
  Widget frameDetail(
    BuildContext context, {
    required Key key,
    required bool sidebarCollapsed,
    required Widget child,
  }) =>
      // The detail owns the window ground here: it paints the bg-base fill
      // and the ambient layer inside the detail bounds only.
      LicoWindowGround(
        key: key,
        color: context.layoutPalette.background,
        child: child,
      );
}

/// Dashboard plain Settings: the destination hosts its own section
/// list beside the content inside the main view, so the shared panel renders
/// the content alone and both sides follow the shared section channel.
final class DashboardPlainSettingsPresentation
    implements LayoutSettingsPresentation {
  const DashboardPlainSettingsPresentation();

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
