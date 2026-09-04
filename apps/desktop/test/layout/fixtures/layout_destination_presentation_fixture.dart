import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/layout/layout_destination_presentation.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/shared/layout_palette_projection.dart';
import 'package:licoup/src/frontend/shared/ui/lico_content_spacing.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

/// Test-only explicit visual contract for shared feature widget tests.
///
/// Production code must receive these strategies from its active
/// profile/surface bundle; this fixture deliberately supplies no fallback.
final class FixtureLayoutPresentationScope extends StatelessWidget {
  const FixtureLayoutPresentationScope({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return LayoutPaletteScope(
      palette: layoutPaletteFromColors(colors),
      child: LayoutDestinationPresentationScope(
        agents: const FixtureLayoutAgentsPresentation(),
        settings: const FixtureLayoutSettingsPresentation(),
        child: child,
      ),
    );
  }
}

final class FixtureLayoutAgentsPresentation
    implements LayoutAgentsPresentation {
  const FixtureLayoutAgentsPresentation();

  static const double _inset = 12;
  static const double _radius = 16;

  @override
  Color canvasColor(LayoutPalette palette) => palette.background;

  @override
  double get sidebarOuterHorizontalExtent => 0;

  @override
  double get detailOuterHorizontalExtent => _inset;

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
        sidebarCollapsed ? _inset : 0,
        _inset,
        _inset,
        _inset,
      ),
      child: DecoratedBox(
        key: key,
        decoration: BoxDecoration(
          color: palette.surface,
          borderRadius: BorderRadius.circular(_radius),
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
          borderRadius: BorderRadius.circular(_radius),
          child: child,
        ),
      ),
    );
  }
}

final class FixtureLayoutSettingsPresentation
    implements LayoutSettingsPresentation {
  const FixtureLayoutSettingsPresentation();

  @override
  bool get indexHostedByNavigation => false;

  @override
  EdgeInsetsGeometry get contentPadding => const EdgeInsets.symmetric(
    vertical: LicoContentSpacing.item,
    horizontal: 20,
  );

  @override
  EdgeInsetsGeometry get indexPadding =>
      const EdgeInsets.symmetric(vertical: LicoContentSpacing.item);

  @override
  EdgeInsetsGeometry get sectionHeaderPadding => const EdgeInsets.fromLTRB(
    LicoContentSpacing.item,
    LicoContentSpacing.item,
    LicoContentSpacing.item,
    LicoContentSpacing.compact,
  );

  @override
  EdgeInsetsGeometry get rowPadding => const EdgeInsets.fromLTRB(
    LicoContentSpacing.item,
    LicoContentSpacing.item,
    LicoContentSpacing.item,
    LicoContentSpacing.item,
  );

  @override
  EdgeInsetsGeometry get selectorGridPadding => const EdgeInsets.fromLTRB(
    LicoContentSpacing.item,
    LicoContentSpacing.item,
    LicoContentSpacing.item,
    0,
  );

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
    key: key,
    padding: const EdgeInsets.only(bottom: LicoContentSpacing.item),
    child: Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          vertical: LicoContentSpacing.compact,
        ),
        child: child,
      ),
    ),
  );

  @override
  Widget frameSelector(BuildContext context, {required Widget child}) => child;
}
