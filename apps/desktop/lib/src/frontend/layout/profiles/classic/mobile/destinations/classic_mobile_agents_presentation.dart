import 'package:flutter/material.dart';

import 'package:flutter_client/src/frontend/layout/layout_destination_presentation.dart';
import 'package:flutter_client/src/frontend/layout/layout_palette.dart';

/// Classic mobile's destination presentation contract.
///
/// The mobile Agents feature does not render a desktop floating shell, but the
/// bundle still supplies every visual decision explicitly so the shared feature
/// never needs a profile fallback.
final class ClassicMobileAgentsPresentation
    implements LayoutAgentsPresentation {
  const ClassicMobileAgentsPresentation();

  @override
  Color canvasColor(LayoutPalette palette) => palette.background;

  @override
  double get sidebarOuterHorizontalExtent => 0;

  @override
  double get detailOuterHorizontalExtent => 12;

  @override
  EdgeInsetsGeometry get expandedSidebarControlPadding => EdgeInsets.zero;

  @override
  EdgeInsetsGeometry get collapsedSidebarControlPadding => EdgeInsets.zero;

  @override
  bool get showExpandedSidebarControl => false;

  @override
  bool get showCollapsedSidebarControl => false;

  @override
  bool get showConversationSidebarControl => true;

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
  }) => KeyedSubtree(key: key, child: child);
}
