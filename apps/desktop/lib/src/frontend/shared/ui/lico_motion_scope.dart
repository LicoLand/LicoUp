import 'package:flutter/widgets.dart';

import 'package:licoup/src/contracts/presentation/reduce_motion_preference.dart';

/// Gives layout and animated widgets one effective accessibility preference.
/// The tri-state choice follows the system by default and can force motion
/// reduction on or off.
class LicoMotionScope extends StatelessWidget {
  const LicoMotionScope({
    super.key,
    required this.reduceMotion,
    required this.systemReduceMotion,
    required this.child,
  });

  final ReduceMotionPreference reduceMotion;
  final bool systemReduceMotion;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final effective = switch (reduceMotion) {
      ReduceMotionPreference.on => true,
      ReduceMotionPreference.off => false,
      ReduceMotionPreference.system =>
        media.disableAnimations || systemReduceMotion,
    };
    return MediaQuery(
      data: media.copyWith(disableAnimations: effective),
      child: child,
    );
  }
}
