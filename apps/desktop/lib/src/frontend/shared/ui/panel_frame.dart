import 'package:flutter/material.dart';

import 'package:flutter_client/src/frontend/shared/ui/theme.dart';

class PanelFrame extends StatelessWidget {
  const PanelFrame({super.key, required this.child, this.elevated = false});

  final Widget child;
  final bool elevated;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border.all(
          color: elevated
              ? colors.primary.withAlpha(30)
              : colors.line.withAlpha(80),
        ),
        borderRadius: BorderRadius.circular(10),
        boxShadow: elevated
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
