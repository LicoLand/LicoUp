import 'package:flutter/widgets.dart';

import 'package:licoup/src/frontend/binding/projection_builder.dart';
import 'package:licoup/src/presentation/appearance/appearance_projection.dart';
import 'package:licoup/src/presentation/layout/layout_projection.dart';
import 'package:licoup/src/presentation/shell/shell_binding.dart';
import 'package:licoup/src/presentation/shell/shell_projection.dart';

/// Regression fixtures for the counted shell budget.
///
/// Each fixture is the shape of a defect the registered workload conditions
/// must reject: a shell that accepts every projection, and a shell that does UI
/// work every frame. They are mounted through the production root's
/// `homeBuilder` seam over the real shell, so they exercise the same widgets,
/// sources and frame pipeline the measured shell uses.

/// Subscribes to every shell projection and rebuilds on any of them.
///
/// The defect: one owner accepts every update through the counted renderer
/// seam, so one interaction is no longer answered by the region that owns it.
final class GlobalSubscriptionProbe extends StatelessWidget {
  const GlobalSubscriptionProbe({
    super.key,
    required this.binding,
    required this.child,
  });

  final ShellBinding binding;
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      ProjectionBuilder<StatusProjection, int>(
        source: binding.status,
        select: acceptEveryUpdate,
        builder: (context, _) => ProjectionBuilder<NavigationProjection, int>(
          source: binding.navigation,
          select: acceptEveryUpdate,
          builder: (context, _) => ProjectionBuilder<AppearanceProjection, int>(
            source: binding.appearance,
            select: acceptEveryUpdate,
            builder: (context, _) => ProjectionBuilder<LayoutProjection, int>(
              source: binding.layout,
              select: acceptEveryUpdate,
              builder: (context, _) => child,
            ),
          ),
        ),
      );
}

var _accepted = 0;

/// A selector that never compares equal: the defect of a global subscriber.
int acceptEveryUpdate(Object? _) => ++_accepted;

/// Resets the never-equal selector between fixtures.
void resetGlobalSubscriptionProbe() => _accepted = 0;

/// Rebuilds a wide subtree on every frame the shell pumps.
///
/// The defect: the interaction itself is unchanged, but the frame pipeline
/// carries UI work proportional to an animation instead of to the update.
final class UiWorkProbe extends StatefulWidget {
  const UiWorkProbe({super.key, required this.child});

  final Widget child;

  @override
  State<UiWorkProbe> createState() => _UiWorkProbeState();
}

final class _UiWorkProbeState extends State<UiWorkProbe>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 16),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _controller,
    builder: (context, child) => _RebuildEveryFrame(child: child!),
    child: widget.child,
  );
}

/// A wide, static subtree that rebuilds only because its parent rebuilt.
final class _RebuildEveryFrame extends StatelessWidget {
  const _RebuildEveryFrame({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      for (var index = 0; index < 64; index += 1) _UiWorkCell(index: index),
      Expanded(child: child),
    ],
  );
}

final class _UiWorkCell extends StatelessWidget {
  const _UiWorkCell({required this.index});

  final int index;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
