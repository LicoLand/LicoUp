import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';
import 'package:licoup/src/frontend/shared/ui/lico_radius.dart';
import 'package:licoup/src/frontend/shared/ui/theme_colors.dart';

/// Loading placeholders.
///
/// Perceived speed is mostly a layout problem. A spinner in the middle of an
/// empty pane tells the user nothing and forces a second reflow when content
/// lands. A skeleton that matches the shape of the incoming content makes the
/// wait feel shorter and keeps the layout stable.
///
/// Use a skeleton when the shape of the result is known ahead of time —
/// conversation lists, agent rosters, charts, contact rows. Use a spinner only
/// for an action whose result has no shape, such as a running command.
final class LicoSkeleton extends StatefulWidget {
  const LicoSkeleton({
    super.key,
    required this.width,
    required this.height,
    this.radius = LicoRadius.well,
  });

  /// A single text line placeholder.
  const LicoSkeleton.line({super.key, this.width = double.infinity})
    : height = 12,
      radius = 4;

  /// A circular avatar placeholder.
  const LicoSkeleton.avatar({super.key, double size = 36})
    : width = size,
      height = size,
      radius = size / 2;

  final double width;
  final double height;
  final double radius;

  @override
  State<LicoSkeleton> createState() => _LicoSkeletonState();
}

class _LicoSkeletonState extends State<LicoSkeleton>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Ambient loops are created only when motion is allowed. A zero-duration
    // repeating controller would busy-spin the ticker.
    if (context.allowsAmbientMotion) {
      _controller ??=
          AnimationController(vsync: this, duration: LicoMotion.loopLong)
            ..repeat();
    } else {
      _controller?.dispose();
      _controller = null;
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    // Placeholder tones come from the neutral ramp rather than a dedicated
    // token pair, so any preset produces a visible skeleton without having to
    // declare skeleton roles.
    final base = colors.surfaceLow;
    final highlight = colors.surfaceRaised;
    final controller = _controller;

    final decoration = BoxDecoration(
      color: base,
      borderRadius: BorderRadius.circular(widget.radius),
    );

    if (controller == null) {
      return Semantics(
        label: 'loading',
        child: Container(
          width: widget.width,
          height: widget.height,
          decoration: decoration,
        ),
      );
    }

    return Semantics(
      label: 'loading',
      child: SizedBox(
        width: widget.width,
        height: widget.height,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(widget.radius),
          child: AnimatedBuilder(
            animation: controller,
            builder: (context, _) {
              // The sweep travels from fully off the leading edge to fully off
              // the trailing edge so the highlight never appears to pop.
              final progress = controller.value * 3 - 1;
              return DecoratedBox(
                decoration: BoxDecoration(
                  color: base,
                  gradient: LinearGradient(
                    begin: Alignment(progress - 1, 0),
                    end: Alignment(progress + 1, 0),
                    colors: [base, highlight, base],
                    stops: const [0.0, 0.5, 1.0],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

}

/// A stack of line skeletons approximating a paragraph.
final class LicoSkeletonParagraph extends StatelessWidget {
  const LicoSkeletonParagraph({super.key, this.lines = 3});

  final int lines;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var index = 0; index < lines; index += 1) ...[
          if (index > 0) const SizedBox(height: 8),
          // The last line is short so the block reads as prose rather than a
          // solid rectangle.
          FractionallySizedBox(
            alignment: Alignment.centerLeft,
            widthFactor: index == lines - 1 ? 0.55 : 1.0,
            child: const LicoSkeleton.line(),
          ),
        ],
      ],
    );
  }
}

/// A skeleton shaped like one contact or agent row.
final class LicoSkeletonRow extends StatelessWidget {
  const LicoSkeletonRow({super.key, this.avatarSize = 36});

  final double avatarSize;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        LicoSkeleton.avatar(size: avatarSize),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: 0.42,
                child: LicoSkeleton(width: double.infinity, height: 11),
              ),
              const SizedBox(height: 7),
              const FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: 0.72,
                child: LicoSkeleton(width: double.infinity, height: 10),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
