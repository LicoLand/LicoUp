import 'package:flutter/material.dart';

import 'package:flutter_client/src/frontend/layout/layout_destination_presentation.dart';
import 'package:flutter_client/src/frontend/layout/layout_palette.dart';

const LayoutAgentsPresentation studioDesktopAgentsPresentation =
    StudioDesktopAgentsPresentation();
const LayoutSettingsPresentation studioDesktopSettingsPresentation =
    StudioDesktopSettingsPresentation();

/// Studio desktop keeps Agents flush with the continuous Safari canvas.
final class StudioDesktopAgentsPresentation
    implements LayoutAgentsPresentation {
  const StudioDesktopAgentsPresentation();

  @override
  Color canvasColor(LayoutPalette palette) {
    if (palette.isDark) {
      return Color.lerp(palette.background, const Color(0xFF3A3A3C), 0.58)!;
    }
    return Color.lerp(palette.background, palette.surface, 0.72)!;
  }

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

/// Studio desktop's Settings surface is an edge-to-edge inspector.
final class StudioDesktopSettingsPresentation
    implements LayoutSettingsPresentation {
  const StudioDesktopSettingsPresentation();

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
