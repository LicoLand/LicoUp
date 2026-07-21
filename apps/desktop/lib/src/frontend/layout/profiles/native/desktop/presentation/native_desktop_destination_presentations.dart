import 'package:flutter/material.dart';

import 'package:flutter_client/src/frontend/layout/layout_destination_presentation.dart';
import 'package:flutter_client/src/frontend/layout/layout_palette.dart';
import 'package:flutter_client/src/frontend/layout/profiles/native/desktop/shell/native_desktop_chrome_metrics.dart';
import 'package:flutter_client/src/frontend/layout/profiles/native/desktop/shell/native_glass.dart';

const LayoutAgentsPresentation nativeDesktopAgentsPresentation =
    NativeDesktopAgentsPresentation();
const LayoutSettingsPresentation nativeDesktopSettingsPresentation =
    NativeDesktopSettingsPresentation();

/// Native desktop splits Agents inside the shell's workspace container
/// card: the conversation list stays transparent so it reads as the same
/// surface, and the conversation detail nests inside as its own rounded
/// card on the lightest tone.
final class NativeDesktopAgentsPresentation
    implements LayoutAgentsPresentation {
  const NativeDesktopAgentsPresentation();

  @override
  Color canvasColor(LayoutPalette palette) => Colors.transparent;

  @override
  double get sidebarOuterHorizontalExtent => 0;

  @override
  double get detailOuterHorizontalExtent =>
      NativeDesktopChromeMetrics.detailCardMargin +
      NativeDesktopChromeMetrics.detailInset;

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
  }) {
    // The list stays transparent: it reads as the workspace container's own
    // surface, one quiet tonal step above the window background.
    return KeyedSubtree(key: key, child: child);
  }

  @override
  Widget frameDetail(
    BuildContext context, {
    required Key key,
    required bool sidebarCollapsed,
    required Widget child,
  }) {
    return Padding(
      key: key,
      padding: const EdgeInsets.fromLTRB(
        0,
        NativeDesktopChromeMetrics.detailInset,
        NativeDesktopChromeMetrics.detailInset,
        NativeDesktopChromeMetrics.detailInset,
      ),
      child: Container(
        decoration: NativeGlass.innerDetailCard(context.layoutPalette),
        child: ClipRRect(
          borderRadius: NativeGlass.innerDetailCardClipRadius,
          child: child,
        ),
      ),
    );
  }
}

/// Native desktop's Settings surface is an edge-to-edge inspector.
final class NativeDesktopSettingsPresentation
    implements LayoutSettingsPresentation {
  const NativeDesktopSettingsPresentation();

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
