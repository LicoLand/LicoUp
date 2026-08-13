import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/shared/ui/theme.dart';

class MobileComposerSurface extends StatelessWidget {
  const MobileComposerSurface({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: colors.line)),
      ),
      child: child,
    );
  }
}
