import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/shared/ui/lico_loading_effect.dart';

/// Small loading feedback shared by first-page conversation and usage reads.
/// Reduced motion keeps a static arc without scheduling decorative frames.
class LicoLoadingIndicator extends StatelessWidget {
  const LicoLoadingIndicator({
    super.key,
    this.size = 24,
    this.strokeWidth = 2,
    this.color,
    this.value,
    this.semanticsLabel,
  });

  final double size;
  final double strokeWidth;
  final Color? color;
  final double? value;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final effect = LicoLoadingEffectScope.maybeOf(context);
    return Semantics(
      label: semanticsLabel,
      child: RepaintBoundary(
        child: SizedBox.square(
          dimension: size,
          child: TickerMode(
            enabled:
                (effect?.animated ?? true) &&
                !MediaQuery.disableAnimationsOf(context),
            child: value == null && effect != null
                ? effect.indicatorBuilder(context, size, strokeWidth, color)
                : CircularProgressIndicator(
                    value: value,
                    strokeWidth: strokeWidth,
                    color: color,
                  ),
          ),
        ),
      ),
    );
  }
}
