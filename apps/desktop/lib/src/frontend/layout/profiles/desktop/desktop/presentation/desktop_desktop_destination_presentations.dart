import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/layout/layout_destination_presentation.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/tokens/desktop_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/ui/lico_content_spacing.dart';

const LayoutAgentsPresentation desktopDesktopAgentsPresentation =
    DesktopDesktopAgentsPresentation();
const LayoutSettingsPresentation desktopDesktopSettingsPresentation =
    DesktopDesktopSettingsPresentation();

/// Desktop 对话 fullscreen: transparent canvas over the native glass blur so
/// the conversation surface and the floating capsule dock read as one screen;
/// the conversation list floats in a nested glass card.
final class DesktopDesktopAgentsPresentation
    implements LayoutAgentsPresentation {
  const DesktopDesktopAgentsPresentation();

  static const double _listCardInset = 8;
  static const double _listCardRadius = 14;

  @override
  Color canvasColor(LayoutPalette palette) => Colors.transparent;

  @override
  double get sidebarOuterHorizontalExtent => _listCardInset;

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

  // The Desktop dock already carries 设置/功能 plus the 对话 button, so the
  // fullscreen-exclusive conversation app renders no Dashboard nav row.
  @override
  bool get showSidebarBottomNav => false;

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
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        _listCardInset,
        _listCardInset,
        0,
        _listCardInset,
      ),
      child: DecoratedBox(
        key: key,
        decoration: BoxDecoration(
          color: desktopDesktopSurfaceBlack,
          borderRadius: BorderRadius.circular(_listCardRadius),
          border: Border.all(color: DesktopDesktopOnBlack.line, width: 0.5),
          boxShadow: const [
            BoxShadow(
              color: Color(0x59000000),
              blurRadius: 18,
              offset: Offset(0, 6),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(_listCardRadius),
          child: child,
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

/// Desktop settings copy presentation: the settings section index is hosted
/// by the copy's own left navigation card, so the shared SettingsPanel
/// renders its content full width with Desktop-owned insets.
final class DesktopDesktopSettingsPresentation
    implements LayoutSettingsPresentation {
  const DesktopDesktopSettingsPresentation();

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
