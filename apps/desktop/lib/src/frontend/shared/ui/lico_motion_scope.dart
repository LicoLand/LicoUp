import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Gives layout and animated widgets one effective accessibility preference.
/// macOS follows the system; other platforms can additionally reduce motion.
class LicoMotionScope extends StatelessWidget {
  const LicoMotionScope({
    super.key,
    required this.reduceMotion,
    required this.systemReduceMotion,
    required this.child,
  });

  final bool reduceMotion;
  final bool systemReduceMotion;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final effective =
        media.disableAnimations ||
        systemReduceMotion ||
        (defaultTargetPlatform != TargetPlatform.macOS && reduceMotion);
    return MediaQuery(
      data: media.copyWith(disableAnimations: effective),
      child: child,
    );
  }
}
