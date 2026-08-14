import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/layout/layout_destination_presentation.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/shared/ui/lico_content_spacing.dart';

/// Dashboard desktop's frozen non-flush Settings presentation.
final class DashboardDesktopSettingsPresentation
    implements LayoutSettingsPresentation {
  const DashboardDesktopSettingsPresentation();

  @override
  bool get indexHostedByNavigation => true;

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
  }) => KeyedSubtree(
    key: key,
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
