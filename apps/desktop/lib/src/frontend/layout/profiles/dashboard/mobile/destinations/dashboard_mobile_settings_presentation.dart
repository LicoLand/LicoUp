import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/layout/layout_destination_presentation.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/shared/ui/lico_content_spacing.dart';

/// Dashboard mobile's private non-flush Settings strategy.
final class DashboardMobileSettingsPresentation
    implements LayoutSettingsPresentation {
  const DashboardMobileSettingsPresentation();

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
    LicoContentSpacing.section,
    LicoContentSpacing.item,
    LicoContentSpacing.inline,
  );

  @override
  EdgeInsetsGeometry get rowPadding => const EdgeInsets.fromLTRB(
    LicoContentSpacing.item,
    LicoContentSpacing.item,
    LicoContentSpacing.item,
    0,
  );

  @override
  EdgeInsetsGeometry get selectorGridPadding => const EdgeInsets.fromLTRB(
    LicoContentSpacing.item,
    LicoContentSpacing.item,
    LicoContentSpacing.item,
    0,
  );

  @override
  EdgeInsetsGeometry get selectorActionPadding => const EdgeInsets.fromLTRB(
    LicoContentSpacing.item,
    0,
    LicoContentSpacing.item,
    LicoContentSpacing.item,
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
  }) => Padding(
    padding: const EdgeInsets.only(bottom: LicoContentSpacing.item),
    child: KeyedSubtree(
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
    ),
  );

  @override
  Widget frameSelector(BuildContext context, {required Widget child}) => child;
}
