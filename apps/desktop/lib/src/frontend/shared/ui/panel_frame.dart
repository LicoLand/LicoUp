import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/shared/ui/continuous_stroke.dart';
import 'package:licoup/src/frontend/shared/ui/lico_radius.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

class PanelFrame extends StatelessWidget {
  const PanelFrame({super.key, required this.child, this.elevated = false});

  final Widget child;
  final bool elevated;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return DecoratedBox(
      decoration: continuousHairlineDecoration(
        color: colors.surface,
        stroke: elevated
            ? colors.primary.withAlpha(30)
            : colors.line.withAlpha(80),
        borderRadius: BorderRadius.circular(LicoRadius.floating),
        shadows: elevated
            ? [
                BoxShadow(
                  color: colors.primary.withAlpha(6),
                  blurRadius: 8,
                  offset: const Offset(0, 1),
                ),
              ]
            : null,
      ),
      child: child,
    );
  }
}
