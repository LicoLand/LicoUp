import 'package:flutter/material.dart';

/// The client's motion scale.
///
/// Every animated surface reads its duration and curve from here so timing
/// stays coherent across the shell, the conversation surface, and the
/// monitoring panes. Feature code must not invent millisecond literals.
///
/// Durations are deliberately few. If a value does not exist on this scale,
/// the interaction is either a state change ([micro]) or a layout change
/// ([medium]) — pick the nearer one rather than adding a step.
abstract final class LicoMotion {
  /// No animation. Used when a change must read as an immediate fact.
  static const Duration instant = Duration.zero;

  /// Hover, press, focus, and other pointer feedback. Must stay under the
  /// threshold where a control feels laggy to click.
  static const Duration micro = Duration(milliseconds: 120);

  /// Icon state changes, badge pops, small crossfades.
  static const Duration short = Duration(milliseconds: 180);

  /// Panel reveals, list item entry, selection moves.
  static const Duration medium = Duration(milliseconds: 240);

  /// Full-surface transitions and first-paint reveals.
  static const Duration long = Duration(milliseconds: 400);

  /// One cycle of a continuous activity loop (spinner sweep).
  static const Duration loopShort = Duration(milliseconds: 900);

  /// One cycle of an ambient activity loop (edge pulse, shimmer).
  static const Duration loopLong = Duration(milliseconds: 1600);

  /// Standard easing for state changes that begin and end on screen.
  static const Curve standard = Curves.easeOutCubic;

  /// For elements entering the screen or growing.
  static const Curve decelerate = Curves.easeOutQuart;

  /// For elements leaving the screen or shrinking.
  static const Curve accelerate = Curves.easeInCubic;

  /// For a change that should feel deliberate and slightly weighted, such as
  /// a brand indicator settling onto a new destination.
  static const Curve emphasized = Cubic(0.2, 0.0, 0.0, 1.0);

  /// Continuous loops must not ease, or the loop seam becomes visible.
  static const Curve linear = Curves.linear;

  /// The tooltip reveal delay. Shared so every icon-only control agrees.
  static const Duration tooltipWait = Duration(milliseconds: 400);
}

/// Resolves a motion duration against the platform's reduced-motion setting.
///
/// Accessibility requirement: every animation in the client must route through
/// this so a user who disables animations gets a static interface instead of a
/// shortened one.
extension LicoMotionContext on BuildContext {
  /// Returns [duration], or [Duration.zero] when the user has asked for
  /// reduced motion.
  Duration motion(Duration duration) {
    return MediaQuery.disableAnimationsOf(this) ? Duration.zero : duration;
  }

  /// Whether continuous, ambient loops should run at all.
  ///
  /// Looping activity indicators must be replaced by a static state rather
  /// than sped up, because a zero-duration loop busy-spins the ticker.
  bool get allowsAmbientMotion => !MediaQuery.disableAnimationsOf(this);
}
