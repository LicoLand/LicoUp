import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';

final class CanonicalGroupRosterReveal extends StatefulWidget {
  const CanonicalGroupRosterReveal({
    super.key,
    required this.visible,
    required this.child,
  });

  final bool visible;
  final Widget child;

  @override
  State<CanonicalGroupRosterReveal> createState() =>
      CanonicalGroupRosterRevealState();
}

final class CanonicalGroupRosterRevealState
    extends State<CanonicalGroupRosterReveal>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _reveal;
  late bool _renderChild;

  @override
  void initState() {
    super.initState();
    _renderChild = widget.visible;
    _controller = AnimationController(
      vsync: this,
      duration: LicoMotion.medium,
      value: widget.visible ? 1 : 0,
    );
    _reveal = CurvedAnimation(
      parent: _controller,
      curve: LicoMotion.decelerate,
      reverseCurve: LicoMotion.accelerate,
    );
  }

  @override
  void didUpdateWidget(covariant CanonicalGroupRosterReveal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.visible == widget.visible) return;
    _syncVisibility();
  }

  void _syncVisibility() {
    final duration = context.motion(LicoMotion.medium);
    _controller.duration = duration;
    _controller.reverseDuration = duration;
    if (widget.visible) {
      if (!_renderChild) {
        setState(() => _renderChild = true);
      }
      if (duration == Duration.zero) {
        _controller.value = 1;
      } else {
        _controller.forward();
      }
      return;
    }
    if (duration == Duration.zero) {
      _controller.value = 0;
      if (_renderChild) {
        setState(() => _renderChild = false);
      }
      return;
    }
    _controller.reverse().whenCompleteOrCancel(() {
      if (!mounted || widget.visible || !_controller.isDismissed) return;
      setState(() => _renderChild = false);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_renderChild) return const SizedBox.shrink();
    return AnimatedBuilder(
      animation: _reveal,
      child: widget.child,
      builder: (context, child) {
        final reveal = _reveal.value;
        return IgnorePointer(
          ignoring: !widget.visible,
          child: ExcludeSemantics(
            excluding: !widget.visible,
            child: Align(
              key: const Key('canonical-group-roster-alignment'),
              alignment: Alignment.lerp(
                Alignment.topCenter,
                Alignment.center,
                reveal,
              )!,
              child: ClipRect(
                child: Align(
                  alignment: Alignment.topCenter,
                  heightFactor: reveal,
                  child: Opacity(opacity: reveal, child: child),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
