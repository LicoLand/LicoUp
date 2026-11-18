import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/shared/ui/continuous_stroke.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

class MobileComposerSurface extends StatelessWidget {
  const MobileComposerSurface({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return CustomPaint(
      painter: ContinuousEdgeHairlinePainter(
        color: colors.line,
        edge: AxisDirection.up,
      ),
      child: child,
    );
  }
}
