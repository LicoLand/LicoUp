import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/layout/layout_destination_presentation.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/shared/ui/lico_content_spacing.dart';

const LayoutAgentsPresentation dashboardMobileAgentsPresentation =
    DashboardMobileAgentsPresentation();
const LayoutSettingsPresentation dashboardMobileSettingsPresentation =
    DashboardMobileSettingsPresentation();

/// Mobile Dashboard owns its presentation independently from desktop
/// Dashboard; every frame stays flush.
final class DashboardMobileAgentsPresentation
    implements LayoutAgentsPresentation {
  const DashboardMobileAgentsPresentation();

  @override
  Color canvasColor(LayoutPalette palette) => palette.background;

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

  /// The mobile shell itself carries the Pairing / Chats / Settings bottom
  /// tabs, so the Agents conversation list must not re-add the desktop
  /// 功能 / 对话 / 设置 row — that row's 功能 tab targets `agentHub`, which is
  /// not a mobile destination at all. This is the same suppression the
  /// Desktop dock profile applies for its own chrome.
  @override
  bool get showSidebarBottomNav => false;

  @override
  Widget frameWorkspace(
    BuildContext context, {
    required Key key,
    required Widget child,
  }) => child;

  @override
  Widget frameSidebar(
    BuildContext context, {
    required Key key,
    required Widget child,
  }) => child;

  @override
  Widget frameDetail(
    BuildContext context, {
    required Key key,
    required bool sidebarCollapsed,
    required Widget child,
  }) => child;
}

final class DashboardMobileSettingsPresentation
    implements LayoutSettingsPresentation {
  const DashboardMobileSettingsPresentation();

  @override
  bool get indexHostedByNavigation => false;

  @override
  EdgeInsetsGeometry get contentPadding => EdgeInsets.zero;

  @override
  EdgeInsetsGeometry get indexPadding =>
      const EdgeInsets.symmetric(vertical: LicoContentSpacing.compact);

  @override
  EdgeInsetsGeometry get sectionHeaderPadding => const EdgeInsets.fromLTRB(
    LicoContentSpacing.item,
    LicoContentSpacing.item,
    LicoContentSpacing.item,
    LicoContentSpacing.compact,
  );

  @override
  EdgeInsetsGeometry get rowPadding => const EdgeInsets.fromLTRB(
    LicoContentSpacing.item,
    LicoContentSpacing.item,
    LicoContentSpacing.item,
    LicoContentSpacing.item,
  );

  @override
  EdgeInsetsGeometry get selectorGridPadding =>
      const EdgeInsets.only(top: LicoContentSpacing.item);

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
  }) => KeyedSubtree(key: key, child: child);

  @override
  Widget frameSelector(BuildContext context, {required Widget child}) => child;
}
