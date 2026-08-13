import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/layout/layout_destination_presentation.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';

/// Dashboard desktop's flush Agents presentation: the conversation tree list
/// and the document transcript sit edge-to-edge in the window, separated only
/// by a hairline — no floating card, no inset shadow.
final class DashboardDesktopAgentsPresentation
    implements LayoutAgentsPresentation {
  const DashboardDesktopAgentsPresentation();

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
  bool get showExpandedSidebarControl => true;

  @override
  bool get showCollapsedSidebarControl => true;

  @override
  bool get showConversationSidebarControl => true;

  @override
  Widget frameWorkspace(
    BuildContext context, {
    required Key key,
    required Widget child,
  }) => KeyedSubtree(key: key, child: child);

  @override
  Widget frameSidebar(
    BuildContext context, {
    required Key key,
    required Widget child,
  }) {
    final palette = context.layoutPalette;
    return DecoratedBox(
      key: key,
      decoration: BoxDecoration(
        color: palette.background,
        border: Border(
          right: BorderSide(
            color: palette.line.withAlpha(palette.isDark ? 90 : 120),
          ),
        ),
      ),
      child: child,
    );
  }

  @override
  Widget frameDetail(
    BuildContext context, {
    required Key key,
    required bool sidebarCollapsed,
    required Widget child,
  }) {
    return KeyedSubtree(key: key, child: child);
  }
}
