import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/shared/ui/continuous_stroke.dart';
import 'package:licoup/src/frontend/shared/ui/lico_radius.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';
import 'package:licoup/src/frontend/shared/ui/theme_colors.dart';

/// The light-theme "latex cream" surface recipe: a soft raised body that
/// reads like milled latex, not a flat gray block. Secondary controls and
/// fields use [LicoLatexSurface.secondary]; primary actions use
/// [LicoLatexSurface.primary]. Dark mode never reaches these — callers
/// keep the black-glass recipes there.
final class LicoLatexSurface extends StatelessWidget {
  const LicoLatexSurface.secondary({
    super.key,
    required this.child,
    this.pressed = false,
    this.focused = false,
    this.disabled = false,
    this.borderRadius,
    this.padding,
  }) : _variant = _LicoLatexVariant.secondary;

  const LicoLatexSurface.primary({
    super.key,
    required this.child,
    this.pressed = false,
    this.focused = false,
    this.disabled = false,
    this.borderRadius,
    this.padding,
  }) : _variant = _LicoLatexVariant.primary;

  final _LicoLatexVariant _variant;
  final Widget child;

  /// Pressed = a slightly deeper body with the top highlight reduced.
  final bool pressed;
  final bool focused;

  /// Disabled = a muted latex body; the caller mutes the label ink.
  final bool disabled;
  final BorderRadiusGeometry? borderRadius;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final radius = borderRadius ?? BorderRadius.circular(LicoRadius.card);
    if (colors.isDark) {
      final darkPrimary = _variant == _LicoLatexVariant.primary;
      return AnimatedContainer(
        duration: LicoMotion.micro,
        decoration: continuousHairlineDecoration(
          color: darkPrimary
              ? colors.primary.withValues(alpha: 0.22)
              : const Color(0x66000000),
          borderRadius: radius,
          stroke: darkPrimary
              ? colors.primary.withValues(alpha: 0.5)
              : const Color(0x1AFFFFFF),
          strokeWidth: 1,
        ),
        padding: padding,
        child: child,
      );
    }
    final secondary = _variant == _LicoLatexVariant.secondary;
    final primary = colors.primary;
    final primaryStrong = colors.primaryStrong;
    final body = secondary
        ? LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            // Disabled mutes the cream toward the page ground so the
            // muted label stays legible.
            colors: disabled
                ? const [Color(0xFFF8F6F1), Color(0xFFEDE8DF)]
                : const [Color(0xFFFDFCFA), Color(0xFFF4EFE7)],
          )
        : LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            // Taro latex: the lighter taro tint into the brand tone.
            // Disabled washes the violet toward white — still violet, so
            // the dimmed white label keeps its seat on the same family.
            colors: disabled
                ? [
                    Color.lerp(primaryStrong, Colors.white, 0.52)!,
                    Color.lerp(primary, Colors.white, 0.30)!,
                  ]
                : [Color.lerp(primaryStrong, Colors.white, 0.32)!, primary],
          );
    // Pressed deepens the body a touch and dims the top highlight.
    final pressedOverlay = pressed
        ? (secondary ? const Color(0x0A533F2C) : const Color(0x14000000))
        : null;
    return AnimatedContainer(
      duration: LicoMotion.micro,
      decoration: ShapeDecoration(
        shape: ContinuousRoundedBorder(
          borderRadius: radius,
          side: focused
              ? BorderSide(color: primary, width: 2)
              : BorderSide.none,
        ),
        gradient: body,
        color: pressedOverlay,
        shadows: secondary
            ? const [
                BoxShadow(
                  color: Color(0x24533F2C),
                  blurRadius: 10,
                  offset: Offset(0, 3),
                ),
              ]
            : [
                BoxShadow(
                  color: primary.withValues(alpha: disabled ? 0.14 : 0.28),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
      ),
      padding: padding,
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          child,
          // 1 px inner top highlight — the latex lip.
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: IgnorePointer(
              child: Container(
                height: 1,
                decoration: BoxDecoration(
                  color: pressed
                      ? (secondary
                            ? const Color(0x80FFFFFF)
                            : const Color(0x1AFFFFFF))
                      : (secondary
                            ? const Color(0xFFFFFFFF)
                            : const Color(0x59FFFFFF)),
                  borderRadius: BorderRadius.vertical(
                    top: radius.resolve(Directionality.of(context)).topLeft,
                  ),
                ),
              ),
            ),
          ),
          // Faint warm inner bottom shade.
          if (secondary)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: IgnorePointer(
                child: Container(
                  height: 6,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.vertical(
                      bottom: radius
                          .resolve(Directionality.of(context))
                          .bottomLeft,
                    ),
                    gradient: const LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0x00533F2C), Color(0x10533F2C)],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

enum _LicoLatexVariant { secondary, primary }
