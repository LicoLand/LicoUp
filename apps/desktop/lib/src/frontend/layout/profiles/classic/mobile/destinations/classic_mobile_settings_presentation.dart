import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/layout/layout_destination_presentation.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';

/// Classic mobile's frozen non-flush Settings presentation.
final class ClassicMobileSettingsPresentation
    implements LayoutSettingsPresentation {
  const ClassicMobileSettingsPresentation();

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
    padding: const EdgeInsets.only(bottom: 16),
    child: Card(
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
