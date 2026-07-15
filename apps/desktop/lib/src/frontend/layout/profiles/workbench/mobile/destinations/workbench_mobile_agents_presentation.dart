import 'package:flutter/material.dart';

import 'package:flutter_client/src/frontend/layout/layout_destination_presentation.dart';
import 'package:flutter_client/src/frontend/layout/layout_palette.dart';

/// Workbench mobile's private Agents strategy. The mobile workspace does not
/// draw desktop chrome, while retaining the current generic detail treatment
/// if a wide mobile runtime requests it.
final class WorkbenchMobileAgentsPresentation
    implements LayoutAgentsPresentation {
  const WorkbenchMobileAgentsPresentation();

  static const double _floatingCardInset = 12;
  static const double _floatingCardRadius = 16;

  @override
  Color canvasColor(LayoutPalette palette) => palette.background;

  @override
  double get sidebarOuterHorizontalExtent => 0;

  @override
  double get detailOuterHorizontalExtent => _floatingCardInset;

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
  }) {
    final palette = context.layoutPalette;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        sidebarCollapsed ? _floatingCardInset : 0,
        _floatingCardInset,
        _floatingCardInset,
        _floatingCardInset,
      ),
      child: DecoratedBox(
        key: key,
        decoration: BoxDecoration(
          color: palette.surface,
          borderRadius: BorderRadius.circular(_floatingCardRadius),
          border: Border.all(color: palette.line.withAlpha(80)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withAlpha(palette.isDark ? 90 : 28),
              blurRadius: 28,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(_floatingCardRadius),
          child: child,
        ),
      ),
    );
  }
}
