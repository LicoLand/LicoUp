import 'package:flutter/material.dart';

import 'package:flutter_client/src/frontend/layout/layout_destination_presentation.dart';
import 'package:flutter_client/src/frontend/layout/layout_palette.dart';

const LayoutAgentsPresentation nativeMobileAgentsPresentation =
    NativeMobileAgentsPresentation();
const LayoutSettingsPresentation nativeMobileSettingsPresentation =
    NativeMobileSettingsPresentation();

/// Mobile Native owns its presentation independently from desktop Native.
final class NativeMobileAgentsPresentation implements LayoutAgentsPresentation {
  const NativeMobileAgentsPresentation();

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
  }) => child;
}

final class NativeMobileSettingsPresentation
    implements LayoutSettingsPresentation {
  const NativeMobileSettingsPresentation();

  @override
  EdgeInsetsGeometry get contentPadding => EdgeInsets.zero;

  @override
  EdgeInsetsGeometry get indexPadding =>
      const EdgeInsets.symmetric(vertical: 8);

  @override
  EdgeInsetsGeometry get sectionHeaderPadding =>
      const EdgeInsets.fromLTRB(12, 8, 12, 4);

  @override
  EdgeInsetsGeometry get rowPadding => const EdgeInsets.fromLTRB(12, 10, 12, 0);

  @override
  EdgeInsetsGeometry get selectorGridPadding => EdgeInsets.zero;

  @override
  EdgeInsetsGeometry get selectorActionPadding =>
      const EdgeInsets.fromLTRB(12, 0, 12, 8);

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
