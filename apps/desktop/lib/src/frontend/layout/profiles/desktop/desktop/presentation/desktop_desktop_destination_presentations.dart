import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/layout/layout_destination_presentation.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/tokens/desktop_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/ui/continuous_stroke.dart';
import 'package:licoup/src/frontend/shared/ui/lico_content_spacing.dart';

const LayoutAgentsPresentation desktopDesktopAgentsPresentation =
    DesktopDesktopAgentsPresentation();
const LayoutSettingsPresentation desktopDesktopSettingsPresentation =
    DesktopDesktopSettingsPresentation();

/// Desktop conversation presentation: a transparent canvas over the clear
/// window veil so the conversation surface and the bottom composer box read
/// as one screen; the conversation list floats as a glass card flush with
/// the region's left edge so it aligns with the icon strip below it.
final class DesktopDesktopAgentsPresentation
    implements LayoutAgentsPresentation {
  const DesktopDesktopAgentsPresentation();

  @override
  Color canvasColor(LayoutPalette palette) => Colors.transparent;

  @override
  double get sidebarOuterHorizontalExtent => 0;

  // The visible detail keeps a left gap when the list is open (frameDetail);
  // the split math accounts for it through this extent.
  @override
  double get detailOuterHorizontalExtent => DesktopDesktopMetrics.regionGap;

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

  // The Desktop bottom bar already carries 设置/功能 and the permanent
  // conversation pane, so the conversation list renders no Dashboard nav row.
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
    final colors = context.layoutPalette;
    return DecoratedBox(
      key: key,
      decoration: continuousHairlineDecoration(
        color: DesktopDesktopGlass.cardFill(isDark: colors.isDark),
        borderRadius: BorderRadius.circular(DesktopDesktopMetrics.paneRadius),
        stroke: DesktopDesktopGlass.cardBorder(
          colors.line,
          isDark: colors.isDark,
        ),
        strokeWidth: 0.5,
        shadows: DesktopDesktopGlass.cardShadows(isDark: colors.isDark),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(DesktopDesktopMetrics.paneRadius),
        child: child,
      ),
    );
  }

  @override
  Widget frameDetail(
    BuildContext context, {
    required Key key,
    required bool sidebarCollapsed,
    required Widget child,
  }) => KeyedSubtree(
    key: key,
    // With the list visible, the detail shifts right by the same gap the
    // bottom bar puts between the icon strip and the composer box, so the
    // composer lands exactly under the conversation content.
    child: sidebarCollapsed
        ? child
        : Padding(
            padding: const EdgeInsets.only(
              left: DesktopDesktopMetrics.regionGap,
            ),
            child: child,
          ),
  );
}

/// Desktop settings presentation: the Desktop settings surface carries no
/// section index at all — the layout's left pane is already the navigation
/// slot, and a second rail inside settings is redundant chrome. Reporting
/// `indexHostedByNavigation` keeps the shared panel from rendering its own
/// rail, so the sections read as one continuous content page (scroll-spy
/// still publishes the shared section tab channel).
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
