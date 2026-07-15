import 'package:flutter/material.dart';

import 'package:flutter_client/src/frontend/layout/layout_destination_presentation.dart';
import 'package:flutter_client/src/frontend/layout/layout_palette.dart';
import 'package:flutter_client/src/frontend/layout/profiles/bubble/desktop/chrome/bubble_desktop_glass.dart';

const LayoutAgentsPresentation bubbleDesktopAgentsPresentation =
    BubbleDesktopAgentsPresentation();
const LayoutSettingsPresentation bubbleDesktopSettingsPresentation =
    BubbleDesktopSettingsPresentation();

/// Bubble keeps the Agents tree in a floating glass card on desktop.
final class BubbleDesktopAgentsPresentation
    implements LayoutAgentsPresentation {
  const BubbleDesktopAgentsPresentation();

  static const double _sidebarInset = 10;
  static const double _sidebarRadius = 14;

  @override
  Color canvasColor(LayoutPalette palette) => palette.background;

  @override
  double get sidebarOuterHorizontalExtent => _sidebarInset * 2;

  @override
  double get detailOuterHorizontalExtent => 0;

  @override
  EdgeInsetsGeometry get expandedSidebarControlPadding =>
      const EdgeInsets.fromLTRB(10, 10, 10, 4);

  @override
  EdgeInsetsGeometry get collapsedSidebarControlPadding =>
      const EdgeInsets.fromLTRB(10, 10, 0, 10);

  @override
  bool get showExpandedSidebarControl => true;

  @override
  bool get showCollapsedSidebarControl => true;

  @override
  bool get showConversationSidebarControl => false;

  @override
  Widget frameSidebar(
    BuildContext context, {
    required Key key,
    required Widget child,
  }) {
    final palette = context.layoutPalette;
    const radius = BorderRadius.all(Radius.circular(_sidebarRadius));
    final sidebarFill = palette.isDark
        ? Color.lerp(palette.background, Colors.black, 0.55)!
        : Color.lerp(palette.background, Colors.black, 0.08)!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(_sidebarInset, 10, 0, 10),
      child: DecoratedBox(
        key: key,
        decoration: BoxDecoration(
          borderRadius: radius,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withAlpha(palette.isDark ? 100 : 30),
              blurRadius: 18,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: BubbleDesktopGlassSurface(
          borderRadius: radius,
          blurSigma: 20,
          fillAlpha: 0,
          borderAlpha: palette.isDark ? 36 : 50,
          child: ColoredBox(color: sidebarFill, child: child),
        ),
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

/// Bubble's existing card-based Settings presentation on desktop.
final class BubbleDesktopSettingsPresentation
    implements LayoutSettingsPresentation {
  const BubbleDesktopSettingsPresentation();

  @override
  EdgeInsetsGeometry get contentPadding =>
      const EdgeInsets.symmetric(vertical: 16, horizontal: 20);

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
  }) {
    final palette = context.layoutPalette;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      width: 180,
      decoration: BoxDecoration(
        color: hovered
            ? palette.surface.withAlpha(palette.isDark ? 30 : 18)
            : Colors.transparent,
        border: Border(right: BorderSide(color: palette.line.withAlpha(60))),
      ),
      child: child,
    );
  }

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
