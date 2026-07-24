import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/layout/layout_destination_presentation.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';

const LayoutAgentsPresentation bubbleMobileAgentsPresentation =
    BubbleMobileAgentsPresentation();
const LayoutSettingsPresentation bubbleMobileSettingsPresentation =
    BubbleMobileSettingsPresentation();

/// Mobile does not add a second frame around the shared Agents surface.
final class BubbleMobileAgentsPresentation implements LayoutAgentsPresentation {
  const BubbleMobileAgentsPresentation();

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

  @override
  Widget frameSidebar(
    BuildContext context, {
    required Key key,
    required Widget child,
  }) => KeyedSubtree(key: key, child: child);

  @override
  Widget frameDetail(
    BuildContext context, {
    required Key key,
    required bool sidebarCollapsed,
    required Widget child,
  }) => KeyedSubtree(key: key, child: child);
}

/// Bubble mobile keeps the original compact Settings list padding.
final class BubbleMobileSettingsPresentation
    implements LayoutSettingsPresentation {
  const BubbleMobileSettingsPresentation();

  @override
  EdgeInsetsGeometry get contentPadding =>
      const EdgeInsets.symmetric(vertical: 8);

  @override
  EdgeInsetsGeometry get indexPadding =>
      const EdgeInsets.symmetric(vertical: 12);

  @override
  EdgeInsetsGeometry get sectionHeaderPadding =>
      const EdgeInsets.fromLTRB(16, 14, 16, 4);

  @override
  EdgeInsetsGeometry get rowPadding => const EdgeInsets.fromLTRB(16, 14, 16, 0);

  @override
  EdgeInsetsGeometry get selectorGridPadding =>
      const EdgeInsets.fromLTRB(16, 8, 16, 0);

  @override
  EdgeInsetsGeometry get selectorActionPadding =>
      const EdgeInsets.fromLTRB(16, 0, 16, 14);

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
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Card(
      key: key,
      elevation: 0,
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: child,
      ),
    ),
  );

  @override
  Widget frameSelector(BuildContext context, {required Widget child}) => child;
}
