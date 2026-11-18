import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/shared/ui/apple_control_metrics.dart';
import 'package:licoup/src/frontend/shared/ui/apple_glass.dart';
import 'package:licoup/src/frontend/shared/ui/continuous_stroke.dart';
import 'package:licoup/src/frontend/shared/ui/theme_colors.dart';
import 'package:licoup/src/frontend/shared/ui/lico_latex_surface.dart';
import 'package:licoup/src/frontend/shared/ui/lico_typography.dart';

/// Shared Apple-leaning button styles for remaining page actions.
abstract final class AppleControlButtons {
  static ButtonStyle glassFilled(
    LicoThemeColors colors, {
    String? fontFamily,
    List<String>? fontFamilyFallback,
  }) {
    final family = fontFamily ?? LicoTypography.platformSansFamily;
    final fallback = fontFamilyFallback ?? LicoTypography.sansFallback;
    // Primary: dark = accent-tinted glass with a soft accent glow; light =
    // taro latex — a lighter brand wash with a soft taro shadow.
    final base = colors.isDark
        ? colors.accent.withValues(alpha: 0.22)
        : colors.primary.withValues(alpha: 0.85);
    return ButtonStyle(
      elevation: WidgetStatePropertyAll(colors.isDark ? 0 : 2),
      shadowColor: WidgetStatePropertyAll(
        colors.isDark
            ? colors.brandGlow.withValues(alpha: 0.5)
            : colors.primary.withValues(alpha: 0.28),
      ),
      // Light paints the taro latex surface behind every themed button;
      // dark keeps the flat accent-glass fill.
      backgroundBuilder: colors.isDark
          ? null
          : (context, states, child) => LicoLatexSurface.primary(
              pressed: states.contains(WidgetState.pressed),
              focused: states.contains(WidgetState.focused),
              disabled: states.contains(WidgetState.disabled),
              borderRadius: BorderRadius.circular(
                AppleControlMetrics.controlCornerRadius,
              ),
              child: child ?? const SizedBox.shrink(),
            ),
      backgroundColor: WidgetStateProperty.resolveWith((states) {
        // Light resolves the same latex base under the painted surface,
        // keeping the shared fill contract a theme-resolvable value.
        if (states.contains(WidgetState.disabled)) {
          return base.withValues(alpha: 0.35);
        }
        if (states.contains(WidgetState.pressed)) {
          return Color.alphaBlend(colors.pressedOverlay, base);
        }
        if (states.contains(WidgetState.hovered)) {
          return Color.alphaBlend(colors.hoverOverlay, base);
        }
        return base;
      }),
      foregroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) {
          // The taro latex keeps its violet body while disabled, so the
          // label stays in the same ink-on-primary family, only dimmed.
          // Dark mode mutes the ink on the accent glass instead.
          return colors.isDark
              ? colors.textMuted
              : colors.textOnPrimary.withValues(alpha: 0.62);
        }
        return colors.isDark ? colors.accent : Colors.white;
      }),
      side: WidgetStateProperty.resolveWith((states) {
        final enabled = !states.contains(WidgetState.disabled);
        return BorderSide(
          color: colors.isDark
              ? (enabled
                    ? colors.accent.withValues(alpha: 0.5)
                    : colors.accent.withValues(alpha: 0.2))
              : Colors.transparent,
          width: AppleControlMetrics.hairline,
        );
      }),
      textStyle: WidgetStatePropertyAll(
        TextStyle(
          fontFamily: family,
          fontFamilyFallback: fallback,
          fontSize: 13,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.08,
        ),
      ),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      ),
      minimumSize: const WidgetStatePropertyAll(Size(0, 34)),
      shape: WidgetStatePropertyAll(
        ContinuousRoundedBorder(
          borderRadius: BorderRadius.circular(
            AppleControlMetrics.controlCornerRadius,
          ),
        ),
      ),
    );
  }

  static ButtonStyle glassOutlined(
    LicoThemeColors colors, {
    String? fontFamily,
    List<String>? fontFamilyFallback,
  }) {
    final family = fontFamily ?? LicoTypography.platformSansFamily;
    final fallback = fontFamilyFallback ?? LicoTypography.sansFallback;
    // Secondary: dark = black-mask glass (40%) with a faint white hairline;
    // light = milk latex — a soft cream surface with a warm shadow, no
    // hard border.
    final base = colors.isDark ? const Color(0x66000000) : colors.surfaceRaised;
    return ButtonStyle(
      backgroundBuilder: colors.isDark
          ? null
          : (context, states, child) => LicoLatexSurface.secondary(
              pressed: states.contains(WidgetState.pressed),
              focused: states.contains(WidgetState.focused),
              disabled: states.contains(WidgetState.disabled),
              borderRadius: BorderRadius.circular(
                AppleControlMetrics.controlCornerRadius,
              ),
              child: child ?? const SizedBox.shrink(),
            ),
      elevation: WidgetStatePropertyAll(colors.isDark ? 0 : 1.5),
      shadowColor: WidgetStatePropertyAll(
        colors.isDark
            ? Colors.transparent
            : colors.primary.withValues(alpha: 0.16),
      ),
      backgroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) {
          return base.withValues(alpha: 0.5);
        }
        if (states.contains(WidgetState.hovered) ||
            states.contains(WidgetState.pressed)) {
          return Color.alphaBlend(colors.hoverOverlay, base);
        }
        return base;
      }),
      foregroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) {
          return colors.textMuted;
        }
        return colors.text;
      }),
      side: WidgetStateProperty.resolveWith((states) {
        final enabled = !states.contains(WidgetState.disabled);
        return BorderSide(
          color: colors.isDark
              ? (enabled ? const Color(0x1AFFFFFF) : const Color(0x0DFFFFFF))
              : Colors.transparent,
          width: AppleControlMetrics.hairline,
        );
      }),
      textStyle: WidgetStatePropertyAll(
        TextStyle(
          fontFamily: family,
          fontFamilyFallback: fallback,
          fontSize: 13,
          fontWeight: FontWeight.w500,
          letterSpacing: -0.08,
        ),
      ),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      ),
      minimumSize: const WidgetStatePropertyAll(Size(0, 34)),
      shape: WidgetStatePropertyAll(
        ContinuousRoundedBorder(
          borderRadius: BorderRadius.circular(
            AppleControlMetrics.controlCornerRadius,
          ),
        ),
      ),
    );
  }

  static ButtonStyle glassText(
    LicoThemeColors colors, {
    String? fontFamily,
    List<String>? fontFamilyFallback,
  }) {
    final family = fontFamily ?? LicoTypography.platformSansFamily;
    final fallback = fontFamilyFallback ?? LicoTypography.sansFallback;
    return TextButton.styleFrom(
      foregroundColor: colors.accent,
      disabledForegroundColor: colors.textDisabled,
      textStyle: TextStyle(
        fontFamily: family,
        fontFamilyFallback: fallback,
        fontSize: 13,
        fontWeight: FontWeight.w500,
        letterSpacing: -0.08,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      minimumSize: const Size(0, 32),
      shape: ContinuousRoundedBorder(
        borderRadius: BorderRadius.circular(
          AppleControlMetrics.controlCornerRadius,
        ),
      ),
    );
  }
}

/// Compact glass action used by toolbars and page headers.
class AppleGlassActionButton extends StatelessWidget {
  const AppleGlassActionButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.emphasized = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final enabled = onPressed != null;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(
          AppleControlMetrics.controlCornerRadius,
        ),
        child: AppleGlassSurface(
          borderRadius: BorderRadius.circular(
            AppleControlMetrics.controlCornerRadius,
          ),
          focused: emphasized && enabled,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  Icon(
                    icon,
                    size: 15,
                    color: enabled ? colors.text : colors.textDisabled,
                  ),
                  const SizedBox(width: 6),
                ],
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: enabled ? colors.text : colors.textDisabled,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
